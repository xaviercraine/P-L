-- Conv 12: Champion Payout Tracking
-- fn_calculate_champion_payouts + fn_get_accruing_champion_earnings + pg_cron

-- 1. Monthly payout calculation function
CREATE OR REPLACE FUNCTION fn_calculate_champion_payouts()
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  h RECORD;
  hotel_local_date date;
  prev_month_start date;
  prev_month_end date;
BEGIN
  FOR h IN SELECT id, timezone FROM hotels LOOP
    hotel_local_date := (NOW() AT TIME ZONE h.timezone)::date;
    prev_month_start := (date_trunc('month', hotel_local_date) - interval '1 month')::date;
    prev_month_end   := (date_trunc('month', hotel_local_date) - interval '1 day')::date;

    INSERT INTO champion_payouts (
      id,
      champion_id,
      hotel_id,
      period_start,
      period_end,
      total_reservation_revenue_cents,
      champion_earnings_cents,
      reservations_count,
      payout_status
    )
    SELECT
      gen_random_uuid(),
      cdl.champion_id,
      h.id,
      prev_month_start,
      prev_month_end,
      COALESCE(SUM(r.price_cents), 0),
      COALESCE(SUM(r.champion_fee_cents), 0),
      COUNT(r.id),
      'calculated'::payout_status
    FROM champion_duty_log cdl
    JOIN reservations r
      ON  r.hotel_id        = h.id
      AND r.reservation_date = cdl.duty_date
      AND r.payment_status   = 'succeeded'
    WHERE cdl.hotel_id  = h.id
      AND cdl.duty_date BETWEEN prev_month_start AND prev_month_end
    GROUP BY cdl.champion_id
    HAVING COUNT(r.id) > 0
    ON CONFLICT (champion_id, hotel_id, period_start, period_end) DO NOTHING;
  END LOOP;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_calculate_champion_payouts() FROM public, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_calculate_champion_payouts() TO service_role;

-- 2. Accruing earnings helper (current month, live totals)
CREATE OR REPLACE FUNCTION fn_get_accruing_champion_earnings(p_hotel_id uuid)
RETURNS TABLE (
  champion_id uuid,
  champion_name text,
  total_reservation_revenue_cents bigint,
  champion_earnings_cents bigint,
  reservations_count bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_tz text;
  v_month_start date;
  v_today date;
BEGIN
  SELECT timezone INTO v_tz FROM hotels WHERE id = p_hotel_id;
  v_today := (NOW() AT TIME ZONE v_tz)::date;
  v_month_start := date_trunc('month', v_today)::date;

  RETURN QUERY
  SELECT
    cdl.champion_id,
    s.full_name AS champion_name,
    COALESCE(SUM(r.price_cents), 0)::bigint,
    COALESCE(SUM(r.champion_fee_cents), 0)::bigint,
    COUNT(r.id)::bigint
  FROM champion_duty_log cdl
  JOIN staff s ON s.id = cdl.champion_id
  JOIN reservations r
    ON  r.hotel_id        = p_hotel_id
    AND r.reservation_date = cdl.duty_date
    AND r.payment_status   = 'succeeded'
  WHERE cdl.hotel_id = p_hotel_id
    AND cdl.duty_date BETWEEN v_month_start AND v_today
  GROUP BY cdl.champion_id, s.full_name;
END;
$$;

REVOKE EXECUTE ON FUNCTION fn_get_accruing_champion_earnings(uuid) FROM public, anon, authenticated;
GRANT  EXECUTE ON FUNCTION fn_get_accruing_champion_earnings(uuid) TO service_role;
GRANT  EXECUTE ON FUNCTION fn_get_accruing_champion_earnings(uuid) TO authenticated;

-- 3. pg_cron: run on 2nd of every month at 00:00 UTC
SELECT cron.schedule(
  'monthly-champion-payouts',
  '0 0 2 * *',
  $$SELECT fn_calculate_champion_payouts()$$
);
