-- ============================================================================
-- Migration 007: Mock reservation creation function
-- Conv 8 — Reservation Creation (Mocked)
-- ============================================================================
-- This function handles the full reservation flow in a single transaction:
--   1. Lock the seat row (FOR UPDATE) to serialize concurrent bookings
--   2. Verify seat belongs to hotel and is active/verified
--   3. Check for conflicting non-terminal reservations (overlap logic)
--   4. Look up active pricing for the seat's zone + time block
--   5. Look up hotel split percentages
--   6. Calculate split amounts (hotel 90%, platform 7%, champion 3%)
--   7. Insert reservation with payment_status = 'succeeded' (mocked)
--   8. Return reservation ID, price, and currency
--
-- In Conv 11, this will be replaced with a version that inserts 'pending'
-- and returns a Stripe Payment Intent client_secret instead.
-- ============================================================================

CREATE OR REPLACE FUNCTION fn_create_reservation_mock(
  p_seat_id     uuid,
  p_hotel_id    uuid,
  p_reservation_date date,
  p_time_block  text,
  p_guest_name  text,
  p_guest_email text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_seat           RECORD;
  v_pricing        RECORD;
  v_hotel          RECORD;
  v_hotel_earnings integer;
  v_platform_fee   integer;
  v_champion_fee   integer;
  v_conflict_count integer;
  v_reservation_id uuid;
BEGIN
  -- ── Step 1: Lock the seat row ──────────────────────────────────────────
  SELECT id, zone_id, hotel_id, is_active, verified_at
    INTO v_seat
    FROM seats
   WHERE id = p_seat_id
   FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'seat_not_found');
  END IF;

  -- Verify seat belongs to the specified hotel
  IF v_seat.hotel_id != p_hotel_id THEN
    RETURN jsonb_build_object('error', 'seat_not_found');
  END IF;

  -- Verify seat is active and verified
  IF v_seat.is_active = false OR v_seat.verified_at IS NULL THEN
    RETURN jsonb_build_object('error', 'seat_not_available');
  END IF;

  -- ── Step 2: Check for conflicting reservations ─────────────────────────
  SELECT COUNT(*) INTO v_conflict_count
    FROM reservations r
   WHERE r.seat_id = p_seat_id
     AND r.reservation_date = p_reservation_date
     AND r.payment_status NOT IN ('expired', 'failed', 'refunded')
     AND (
           r.time_block = 'full_day'::time_block
        OR p_time_block::time_block = 'full_day'::time_block
        OR r.time_block = p_time_block::time_block
     );

  IF v_conflict_count > 0 THEN
    RETURN jsonb_build_object('error', 'seat_already_reserved');
  END IF;

  -- ── Step 3: Look up pricing ────────────────────────────────────────────
  SELECT id, price_cents, currency
    INTO v_pricing
    FROM pricing
   WHERE zone_id = v_seat.zone_id
     AND time_block = p_time_block::time_block
     AND is_active = true
   LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'pricing_not_found');
  END IF;

  -- ── Step 4: Look up hotel split percentages ────────────────────────────
  SELECT hotel_split_pct, platform_split_pct, champion_split_pct
    INTO v_hotel
    FROM hotels
   WHERE id = p_hotel_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('error', 'hotel_not_found');
  END IF;

  -- ── Step 5: Calculate split amounts ────────────────────────────────────
  -- Hotel gets its percentage, platform gets its percentage,
  -- champion gets the remainder to ensure amounts sum exactly to price.
  v_hotel_earnings := ROUND(v_pricing.price_cents * v_hotel.hotel_split_pct / 100.0);
  v_platform_fee   := ROUND(v_pricing.price_cents * v_hotel.platform_split_pct / 100.0);
  v_champion_fee   := v_pricing.price_cents - v_hotel_earnings - v_platform_fee;

  -- ── Step 6: Insert reservation ─────────────────────────────────────────
  INSERT INTO reservations (
    seat_id,
    hotel_id,
    reservation_date,
    time_block,
    guest_name,
    guest_email,
    price_cents,
    currency,
    hotel_earnings_cents,
    platform_fee_cents,
    champion_fee_cents,
    payment_status
  ) VALUES (
    p_seat_id,
    p_hotel_id,
    p_reservation_date,
    p_time_block::time_block,
    p_guest_name,
    p_guest_email,
    v_pricing.price_cents,
    v_pricing.currency,
    v_hotel_earnings,
    v_platform_fee,
    v_champion_fee,
    'succeeded'::payment_status
  )
  RETURNING id INTO v_reservation_id;

  -- ── Step 7: Return success ─────────────────────────────────────────────
  RETURN jsonb_build_object(
    'reservation_id', v_reservation_id,
    'price_cents',    v_pricing.price_cents,
    'currency',       v_pricing.currency
  );

EXCEPTION
  WHEN unique_violation THEN
    -- Overlap trigger or partial unique index caught a conflict
    RETURN jsonb_build_object('error', 'seat_already_reserved');
  WHEN OTHERS THEN
    RAISE WARNING 'fn_create_reservation_mock error: %', SQLERRM;
    RETURN jsonb_build_object('error', 'server_error');
END;
$$;

-- ── Permissions ──────────────────────────────────────────────────────────
-- Only Edge Functions (service_role) can call this function.
-- Anon and authenticated users cannot call it directly.
REVOKE ALL ON FUNCTION fn_create_reservation_mock FROM PUBLIC;
REVOKE ALL ON FUNCTION fn_create_reservation_mock FROM anon;
REVOKE ALL ON FUNCTION fn_create_reservation_mock FROM authenticated;
GRANT EXECUTE ON FUNCTION fn_create_reservation_mock TO service_role;
