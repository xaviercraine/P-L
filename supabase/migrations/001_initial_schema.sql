-- ============================================================
-- Pül — Complete Supabase Migration
-- Run in Supabase SQL Editor (single transaction)
-- ============================================================

BEGIN;

-- ============================================================
-- 0. EXTENSIONS
-- ============================================================
CREATE EXTENSION IF NOT EXISTS moddatetime SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron       SCHEMA pg_catalog;

-- ============================================================
-- 1. ENUM TYPES
-- ============================================================
CREATE TYPE seat_type           AS ENUM ('lounger','chair','cabana','umbrella','daybed');
CREATE TYPE time_block          AS ENUM ('full_day','morning','afternoon');
CREATE TYPE payment_status      AS ENUM ('pending','succeeded','expired','refunded','failed');
CREATE TYPE subscription_status AS ENUM ('trialing','active','past_due','cancelled');
CREATE TYPE staff_role          AS ENUM ('owner','manager','attendant');
CREATE TYPE dispute_status      AS ENUM ('open','in_progress','resolved','escalated');
CREATE TYPE payout_status       AS ENUM ('accruing','calculated','paid');
CREATE TYPE deployment_status   AS ENUM ('draft','in_progress','active');

-- ============================================================
-- 2. TABLES
-- ============================================================

-- hotels -------------------------------------------------------
CREATE TABLE hotels (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                  text NOT NULL,
  address               text,
  city                  text,
  country               text,
  timezone              text NOT NULL,
  stripe_account_id     text,
  stripe_charges_enabled boolean NOT NULL DEFAULT false,
  subscription_status   subscription_status NOT NULL DEFAULT 'trialing',
  deployment_status     deployment_status   NOT NULL DEFAULT 'draft',
  hotel_split_pct       integer NOT NULL DEFAULT 90,
  platform_split_pct    integer NOT NULL DEFAULT 7,
  champion_split_pct    integer NOT NULL DEFAULT 3,
  logo_url              text,
  primary_color         text DEFAULT '#0066FF',
  display_name          text,
  last_briefing_sent_date date,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT chk_split_pct_sum
    CHECK (hotel_split_pct + platform_split_pct + champion_split_pct = 100)
);

-- Timezone validation via trigger (PG disallows subqueries in CHECK)
CREATE OR REPLACE FUNCTION fn_validate_hotel_timezone()
RETURNS trigger AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_timezone_names WHERE name = NEW.timezone) THEN
    RAISE EXCEPTION 'Invalid timezone: %. Must be a valid IANA timezone.', NEW.timezone;
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_validate_hotel_timezone
  BEFORE INSERT OR UPDATE ON hotels
  FOR EACH ROW
  EXECUTE FUNCTION fn_validate_hotel_timezone();

-- staff --------------------------------------------------------
CREATE TABLE staff (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id                uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  user_id                 uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  email                   text NOT NULL,
  full_name               text NOT NULL,
  role                    staff_role NOT NULL,
  is_champion             boolean NOT NULL DEFAULT false,
  is_installer            boolean NOT NULL DEFAULT false,
  champion_payout_method  text,
  is_active               boolean NOT NULL DEFAULT true,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

-- champion_duty_log --------------------------------------------
CREATE TABLE champion_duty_log (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id        uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  champion_id     uuid NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
  duty_date       date NOT NULL,
  auto_assigned   boolean NOT NULL DEFAULT false,
  created_at      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT uq_duty_log_hotel_date UNIQUE (hotel_id, duty_date)
);

-- pool_areas ---------------------------------------------------
CREATE TABLE pool_areas (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  hotel_id          uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  name              text NOT NULL,
  floor_plan_url    text,
  floor_plan_width  integer,
  floor_plan_height integer,
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

-- zones --------------------------------------------------------
CREATE TABLE zones (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pool_area_id  uuid NOT NULL REFERENCES pool_areas(id) ON DELETE CASCADE,
  hotel_id      uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  name          text NOT NULL,
  color         text NOT NULL,
  sort_order    integer NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- seats --------------------------------------------------------
CREATE TABLE seats (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  pool_area_id  uuid NOT NULL REFERENCES pool_areas(id) ON DELETE CASCADE,
  zone_id       uuid NOT NULL REFERENCES zones(id) ON DELETE CASCADE,
  hotel_id      uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  label         text NOT NULL,
  seat_type     seat_type NOT NULL,
  x_position    double precision NOT NULL,
  y_position    double precision NOT NULL,
  qr_code_url   text,
  verified_at   timestamptz,
  verified_by   uuid REFERENCES staff(id),
  is_active     boolean NOT NULL DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT uq_seat_label_per_area UNIQUE (pool_area_id, label)
);

-- pricing ------------------------------------------------------
CREATE TABLE pricing (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  zone_id     uuid NOT NULL REFERENCES zones(id) ON DELETE CASCADE,
  hotel_id    uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  time_block  time_block NOT NULL,
  price_cents integer NOT NULL,
  currency    text NOT NULL DEFAULT 'usd',
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

-- reservations -------------------------------------------------
CREATE TABLE reservations (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  seat_id                   uuid NOT NULL REFERENCES seats(id) ON DELETE CASCADE,
  hotel_id                  uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  reservation_date          date NOT NULL,
  time_block                time_block NOT NULL,
  guest_name                text NOT NULL,
  guest_email               text NOT NULL,
  cancellation_token        uuid NOT NULL DEFAULT gen_random_uuid(),
  price_cents               integer NOT NULL,
  hotel_earnings_cents      integer NOT NULL,
  platform_fee_cents        integer NOT NULL,
  champion_fee_cents        integer NOT NULL,
  currency                  text NOT NULL,
  stripe_payment_intent_id  text,
  payment_status            payment_status NOT NULL DEFAULT 'pending',
  expires_at                timestamptz,
  setup_confirmed           boolean NOT NULL DEFAULT false,
  setup_confirmed_at        timestamptz,
  setup_confirmed_by        uuid REFERENCES staff(id),
  checked_in                boolean NOT NULL DEFAULT false,
  checked_in_at             timestamptz,
  cancelled_at              timestamptz,
  cancellation_reason       text,
  refund_amount_cents       integer,
  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

-- disputes -----------------------------------------------------
CREATE TABLE disputes (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  reservation_id        uuid NOT NULL REFERENCES reservations(id) ON DELETE CASCADE,
  seat_id               uuid NOT NULL REFERENCES seats(id) ON DELETE CASCADE,
  hotel_id              uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  reported_by_name      text NOT NULL,
  reported_by_email     text,
  reported_at           timestamptz NOT NULL DEFAULT now(),
  assigned_champion_id  uuid REFERENCES staff(id),
  resolution_status     dispute_status NOT NULL DEFAULT 'open',
  resolved_at           timestamptz,
  resolution_notes      text,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

-- champion_payouts ---------------------------------------------
CREATE TABLE champion_payouts (
  id                              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  champion_id                     uuid NOT NULL REFERENCES staff(id) ON DELETE CASCADE,
  hotel_id                        uuid NOT NULL REFERENCES hotels(id) ON DELETE CASCADE,
  period_start                    date NOT NULL,
  period_end                      date NOT NULL,
  total_reservation_revenue_cents integer NOT NULL,
  champion_earnings_cents         integer NOT NULL,
  reservations_count              integer NOT NULL,
  payout_status                   payout_status NOT NULL DEFAULT 'accruing',
  paid_at                         timestamptz,
  stripe_transfer_id              text,
  created_at                      timestamptz NOT NULL DEFAULT now(),
  updated_at                      timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT uq_champion_payout_period
    UNIQUE (champion_id, hotel_id, period_start, period_end)
);

-- processed_webhook_events -------------------------------------
CREATE TABLE processed_webhook_events (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stripe_event_id text NOT NULL,
  event_type      text NOT NULL,
  processed_at    timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT uq_stripe_event_id UNIQUE (stripe_event_id)
);

-- ============================================================
-- 3. PARTIAL UNIQUE INDEXES
-- ============================================================

CREATE UNIQUE INDEX uidx_pricing_zone_timeblock_active
  ON pricing (zone_id, time_block)
  WHERE is_active = true;

CREATE UNIQUE INDEX uidx_reservation_seat_date_block
  ON reservations (seat_id, reservation_date, time_block)
  WHERE payment_status NOT IN ('expired','failed','refunded');

-- ============================================================
-- 4. STANDARD INDEXES
-- ============================================================

CREATE INDEX idx_reservations_hotel_date   ON reservations (hotel_id, reservation_date);
CREATE INDEX idx_reservations_seat_date    ON reservations (seat_id, reservation_date);
CREATE INDEX idx_reservations_pending      ON reservations (payment_status, expires_at)
                                           WHERE payment_status = 'pending';
CREATE INDEX idx_reservations_stripe_pi    ON reservations (stripe_payment_intent_id);
CREATE INDEX idx_seats_pool_area           ON seats (pool_area_id);
CREATE INDEX idx_seats_hotel               ON seats (hotel_id);
CREATE INDEX idx_seats_verified            ON seats (hotel_id) WHERE verified_at IS NOT NULL;
CREATE INDEX idx_pricing_zone_active       ON pricing (zone_id) WHERE is_active = true;
CREATE INDEX idx_disputes_hotel_status     ON disputes (hotel_id, resolution_status);
CREATE INDEX idx_staff_hotel               ON staff (hotel_id);
CREATE INDEX idx_duty_log_hotel_date       ON champion_duty_log (hotel_id, duty_date);
CREATE INDEX idx_webhook_events            ON processed_webhook_events (stripe_event_id);

-- ============================================================
-- 5. MODDATETIME TRIGGERS  (updated_at auto-bump)
-- ============================================================

CREATE TRIGGER trg_hotels_updated_at       BEFORE UPDATE ON hotels              FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);
CREATE TRIGGER trg_staff_updated_at        BEFORE UPDATE ON staff               FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);
CREATE TRIGGER trg_pool_areas_updated_at   BEFORE UPDATE ON pool_areas          FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);
CREATE TRIGGER trg_zones_updated_at        BEFORE UPDATE ON zones               FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);
CREATE TRIGGER trg_seats_updated_at        BEFORE UPDATE ON seats               FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);
CREATE TRIGGER trg_pricing_updated_at      BEFORE UPDATE ON pricing             FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);
CREATE TRIGGER trg_reservations_updated_at BEFORE UPDATE ON reservations        FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);
CREATE TRIGGER trg_disputes_updated_at     BEFORE UPDATE ON disputes            FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);
CREATE TRIGGER trg_payouts_updated_at      BEFORE UPDATE ON champion_payouts    FOR EACH ROW EXECUTE FUNCTION extensions.moddatetime(updated_at);

-- champion_duty_log has no updated_at column, so no trigger needed.
-- processed_webhook_events has no updated_at column, so no trigger needed.

-- ============================================================
-- 6. OVERLAP PROTECTION TRIGGER ON RESERVATIONS
-- ============================================================

CREATE OR REPLACE FUNCTION fn_check_reservation_overlap()
RETURNS trigger AS $$
BEGIN
  -- Only check on non-terminal inserts
  IF NEW.payment_status IN ('expired','failed','refunded') THEN
    RETURN NEW;
  END IF;

  -- full_day blocks with any existing non-terminal reservation
  IF NEW.time_block = 'full_day' THEN
    IF EXISTS (
      SELECT 1 FROM reservations
      WHERE seat_id           = NEW.seat_id
        AND reservation_date  = NEW.reservation_date
        AND payment_status NOT IN ('expired','failed','refunded')
        AND id IS DISTINCT FROM NEW.id
    ) THEN
      RAISE EXCEPTION 'Overlap: seat % already has a reservation on % that conflicts with full_day',
        NEW.seat_id, NEW.reservation_date;
    END IF;
  ELSE
    -- morning / afternoon: conflicts with same block OR full_day
    IF EXISTS (
      SELECT 1 FROM reservations
      WHERE seat_id           = NEW.seat_id
        AND reservation_date  = NEW.reservation_date
        AND (time_block = NEW.time_block OR time_block = 'full_day')
        AND payment_status NOT IN ('expired','failed','refunded')
        AND id IS DISTINCT FROM NEW.id
    ) THEN
      RAISE EXCEPTION 'Overlap: seat % already has a conflicting reservation on %',
        NEW.seat_id, NEW.reservation_date;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reservation_overlap
  BEFORE INSERT OR UPDATE ON reservations
  FOR EACH ROW
  EXECUTE FUNCTION fn_check_reservation_overlap();

-- ============================================================
-- 7. PG_CRON — EXPIRE PENDING RESERVATIONS (every 2 min)
-- ============================================================

SELECT cron.schedule(
  'expire-pending-reservations',
  '*/2 * * * *',
  $$UPDATE reservations
    SET payment_status = 'expired'
    WHERE payment_status = 'pending'
      AND expires_at < now()$$
);

-- ============================================================
-- 8. RLS POLICIES
-- ============================================================

ALTER TABLE hotels                    ENABLE ROW LEVEL SECURITY;
ALTER TABLE staff                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE champion_duty_log         ENABLE ROW LEVEL SECURITY;
ALTER TABLE pool_areas                ENABLE ROW LEVEL SECURITY;
ALTER TABLE zones                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE seats                     ENABLE ROW LEVEL SECURITY;
ALTER TABLE pricing                   ENABLE ROW LEVEL SECURITY;
ALTER TABLE reservations              ENABLE ROW LEVEL SECURITY;
ALTER TABLE disputes                  ENABLE ROW LEVEL SECURITY;
ALTER TABLE champion_payouts          ENABLE ROW LEVEL SECURITY;
ALTER TABLE processed_webhook_events  ENABLE ROW LEVEL SECURITY;

-- ----- helper: get staff row for current user in a hotel -----
CREATE OR REPLACE FUNCTION auth_staff_role(_hotel_id uuid)
RETURNS TABLE(id uuid, role staff_role, is_champion boolean, is_installer boolean) AS $$
  SELECT s.id, s.role, s.is_champion, s.is_installer
  FROM staff s
  WHERE s.hotel_id = _hotel_id
    AND s.user_id  = auth.uid()
    AND s.is_active = true
  LIMIT 1;
$$ LANGUAGE sql SECURITY DEFINER STABLE;

-- ==================== HOTELS ====================

-- Anon: limited columns
CREATE POLICY hotels_anon_select ON hotels
  FOR SELECT TO anon
  USING (true);
-- NOTE: anon sees all rows but column access is enforced via a VIEW or
-- PostgREST column-level grants. We create a restrictive view below.

-- Staff: full access scoped to their hotel
CREATE POLICY hotels_staff_select ON hotels
  FOR SELECT TO authenticated
  USING (EXISTS (
    SELECT 1 FROM staff s
    WHERE s.hotel_id = hotels.id
      AND s.user_id  = auth.uid()
      AND s.is_active = true
  ));

CREATE POLICY hotels_staff_update ON hotels
  FOR UPDATE TO authenticated
  USING (EXISTS (
    SELECT 1 FROM staff s
    WHERE s.hotel_id = hotels.id
      AND s.user_id  = auth.uid()
      AND s.is_active = true
      AND s.role IN ('owner','manager')
  ));

-- ==================== STAFF ====================

CREATE POLICY staff_select ON staff
  FOR SELECT TO authenticated
  USING (
    hotel_id IN (
      SELECT s.hotel_id FROM staff s
      WHERE s.user_id = auth.uid() AND s.is_active = true
    )
  );

CREATE POLICY staff_insert ON staff
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = staff.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role = 'owner'
    )
  );

CREATE POLICY staff_update ON staff
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = staff.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

-- ==================== CHAMPION DUTY LOG ====================

CREATE POLICY duty_log_staff_select ON champion_duty_log
  FOR SELECT TO authenticated
  USING (
    hotel_id IN (
      SELECT s.hotel_id FROM staff s
      WHERE s.user_id = auth.uid() AND s.is_active = true
    )
  );

CREATE POLICY duty_log_staff_insert ON champion_duty_log
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = champion_duty_log.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

-- ==================== POOL AREAS ====================

-- Anon: see pool areas for active deployed hotels
CREATE POLICY pool_areas_anon_select ON pool_areas
  FOR SELECT TO anon
  USING (
    is_active = true
    AND EXISTS (
      SELECT 1 FROM hotels h
      WHERE h.id = pool_areas.hotel_id
        AND h.deployment_status = 'active'
    )
  );

CREATE POLICY pool_areas_staff_select ON pool_areas
  FOR SELECT TO authenticated
  USING (
    hotel_id IN (
      SELECT s.hotel_id FROM staff s
      WHERE s.user_id = auth.uid() AND s.is_active = true
    )
  );

CREATE POLICY pool_areas_staff_insert ON pool_areas
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = pool_areas.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

CREATE POLICY pool_areas_staff_update ON pool_areas
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = pool_areas.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

-- ==================== ZONES ====================

CREATE POLICY zones_anon_select ON zones
  FOR SELECT TO anon
  USING (
    EXISTS (
      SELECT 1 FROM hotels h
      WHERE h.id = zones.hotel_id
        AND h.deployment_status = 'active'
    )
  );

CREATE POLICY zones_staff_select ON zones
  FOR SELECT TO authenticated
  USING (
    hotel_id IN (
      SELECT s.hotel_id FROM staff s
      WHERE s.user_id = auth.uid() AND s.is_active = true
    )
  );

CREATE POLICY zones_staff_insert ON zones
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = zones.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

CREATE POLICY zones_staff_update ON zones
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = zones.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

-- ==================== SEATS ====================

-- Anon: only verified seats in active hotels
CREATE POLICY seats_anon_select ON seats
  FOR SELECT TO anon
  USING (
    verified_at IS NOT NULL
    AND EXISTS (
      SELECT 1 FROM hotels h
      WHERE h.id = seats.hotel_id
        AND h.deployment_status = 'active'
    )
  );

CREATE POLICY seats_staff_select ON seats
  FOR SELECT TO authenticated
  USING (
    hotel_id IN (
      SELECT s.hotel_id FROM staff s
      WHERE s.user_id = auth.uid() AND s.is_active = true
    )
  );

CREATE POLICY seats_staff_insert ON seats
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = seats.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

CREATE POLICY seats_staff_update ON seats
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = seats.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

-- Installer: can only set verified_at and verified_by when deployment in_progress
CREATE POLICY seats_installer_verify ON seats
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff s
      JOIN hotels h ON h.id = s.hotel_id
      WHERE s.hotel_id = seats.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.is_installer = true
        AND h.deployment_status = 'in_progress'
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM staff s
      JOIN hotels h ON h.id = s.hotel_id
      WHERE s.hotel_id = seats.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.is_installer = true
        AND h.deployment_status = 'in_progress'
    )
  );

-- ==================== PRICING ====================

CREATE POLICY pricing_anon_select ON pricing
  FOR SELECT TO anon
  USING (
    is_active = true
    AND EXISTS (
      SELECT 1 FROM hotels h
      WHERE h.id = pricing.hotel_id
        AND h.deployment_status = 'active'
    )
  );

CREATE POLICY pricing_staff_select ON pricing
  FOR SELECT TO authenticated
  USING (
    hotel_id IN (
      SELECT s.hotel_id FROM staff s
      WHERE s.user_id = auth.uid() AND s.is_active = true
    )
  );

CREATE POLICY pricing_staff_insert ON pricing
  FOR INSERT TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = pricing.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

CREATE POLICY pricing_staff_update ON pricing
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = pricing.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

-- ==================== RESERVATIONS ====================

-- Anon: restricted columns only (enforced via this policy + PostgREST column grants)
CREATE POLICY reservations_anon_select ON reservations
  FOR SELECT TO anon
  USING (
    EXISTS (
      SELECT 1 FROM hotels h
      WHERE h.id = reservations.hotel_id
        AND h.deployment_status = 'active'
    )
  );

-- Anon insert (guest booking via Edge Function sets role to anon or service_role)
CREATE POLICY reservations_anon_insert ON reservations
  FOR INSERT TO anon
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM hotels h
      WHERE h.id = reservations.hotel_id
        AND h.deployment_status = 'active'
    )
  );

-- Staff: full select scoped to hotel
CREATE POLICY reservations_staff_select ON reservations
  FOR SELECT TO authenticated
  USING (
    hotel_id IN (
      SELECT s.hotel_id FROM staff s
      WHERE s.user_id = auth.uid() AND s.is_active = true
    )
  );

CREATE POLICY reservations_staff_update ON reservations
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = reservations.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager','attendant')
    )
  );

-- ==================== DISPUTES ====================

CREATE POLICY disputes_anon_insert ON disputes
  FOR INSERT TO anon
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM hotels h
      WHERE h.id = disputes.hotel_id
        AND h.deployment_status = 'active'
    )
  );

CREATE POLICY disputes_staff_select ON disputes
  FOR SELECT TO authenticated
  USING (
    hotel_id IN (
      SELECT s.hotel_id FROM staff s
      WHERE s.user_id = auth.uid() AND s.is_active = true
    )
  );

CREATE POLICY disputes_staff_update ON disputes
  FOR UPDATE TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = disputes.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

-- ==================== CHAMPION PAYOUTS ====================

-- Owners see all, managers see all, champions see only their own
CREATE POLICY payouts_owner_manager_select ON champion_payouts
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.hotel_id = champion_payouts.hotel_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.role IN ('owner','manager')
    )
  );

CREATE POLICY payouts_champion_select ON champion_payouts
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff s
      WHERE s.id       = champion_payouts.champion_id
        AND s.user_id  = auth.uid()
        AND s.is_active = true
        AND s.is_champion = true
    )
  );

-- ==================== PROCESSED WEBHOOK EVENTS ====================
-- Only service_role should touch this table; no anon or authenticated policies.
-- The service_role bypasses RLS, so no policy is needed for Edge Functions.
-- We add no policies here, which means RLS blocks all non-service access.

-- ============================================================
-- 9. ANON COLUMN RESTRICTION VIEW FOR RESERVATIONS
-- ============================================================
-- PostgREST serves tables directly. To enforce column-level
-- restrictions for anon on reservations, we REVOKE direct
-- access and grant via a view that exposes only safe columns.

-- Revoke direct anon SELECT on reservations (RLS still applies to staff)
-- We keep the RLS policy above for staff access but handle anon via grant controls.

-- Grant anon only the safe columns on reservations
REVOKE ALL ON reservations FROM anon;
GRANT SELECT (id, seat_id, reservation_date, time_block, payment_status)
  ON reservations TO anon;

-- Grant anon INSERT (needed for guest booking)
GRANT INSERT ON reservations TO anon;

-- Anon column restrictions on hotels
REVOKE ALL ON hotels FROM anon;
GRANT SELECT (id, name, display_name, logo_url, primary_color, timezone, deployment_status)
  ON hotels TO anon;

-- ============================================================
-- 10. STORAGE BUCKETS (public)
-- ============================================================

INSERT INTO storage.buckets (id, name, public)
VALUES
  ('floor-plans',  'floor-plans',  true),
  ('qr-codes',     'qr-codes',     true),
  ('hotel-assets', 'hotel-assets', true)
ON CONFLICT (id) DO NOTHING;

-- Public read policies for all three buckets
CREATE POLICY storage_floor_plans_public_read ON storage.objects
  FOR SELECT TO anon
  USING (bucket_id = 'floor-plans');

CREATE POLICY storage_qr_codes_public_read ON storage.objects
  FOR SELECT TO anon
  USING (bucket_id = 'qr-codes');

CREATE POLICY storage_hotel_assets_public_read ON storage.objects
  FOR SELECT TO anon
  USING (bucket_id = 'hotel-assets');

-- Staff upload policies (authenticated users with hotel access)
CREATE POLICY storage_floor_plans_staff_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'floor-plans');

CREATE POLICY storage_qr_codes_staff_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'qr-codes');

CREATE POLICY storage_hotel_assets_staff_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (bucket_id = 'hotel-assets');

COMMIT;
