// supabase/functions/create-reservation/index.ts
// Conv 8 — Reservation Creation (Mocked)
//
// HTTP endpoint that validates guest input and delegates to the
// fn_create_reservation_mock database function (which handles locking,
// overlap checks, pricing lookup, split calculation, and insert).
//
// In Conv 11, this will be updated to create a Stripe Payment Intent
// and return a client_secret instead of 'succeeded' status.

import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

// Simple email format check (not exhaustive — server is not the auth gate)
function isValidEmail(email: string): boolean {
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}

serve(async (req) => {
  // ── CORS preflight ───────────────────────────────────────────────────
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const {
      seat_id,
      hotel_id,
      reservation_date,
      time_block,
      guest_name,
      guest_email,
    } = await req.json();

    // ── Input validation ─────────────────────────────────────────────
    if (
      !seat_id ||
      !hotel_id ||
      !reservation_date ||
      !time_block ||
      !guest_name ||
      !guest_email
    ) {
      return jsonResponse(
        { error: "missing_fields", message: "All fields are required." },
        400
      );
    }

    if (!["full_day", "morning", "afternoon"].includes(time_block)) {
      return jsonResponse(
        { error: "invalid_time_block", message: "Invalid time block." },
        400
      );
    }

    if (typeof guest_name !== "string" || guest_name.trim().length < 1) {
      return jsonResponse(
        { error: "invalid_name", message: "Please enter your name." },
        400
      );
    }

    if (!isValidEmail(guest_email)) {
      return jsonResponse(
        { error: "invalid_email", message: "Please enter a valid email." },
        400
      );
    }

    // Basic date format check (YYYY-MM-DD)
    if (!/^\d{4}-\d{2}-\d{2}$/.test(reservation_date)) {
      return jsonResponse(
        { error: "invalid_date", message: "Invalid date format." },
        400
      );
    }

    // ── Call database function ────────────────────────────────────────
    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    const { data, error } = await supabase.rpc("fn_create_reservation_mock", {
      p_seat_id: seat_id,
      p_hotel_id: hotel_id,
      p_reservation_date: reservation_date,
      p_time_block: time_block,
      p_guest_name: guest_name.trim(),
      p_guest_email: guest_email.trim().toLowerCase(),
    });

    if (error) {
      console.error("RPC error:", error);
      return jsonResponse(
        {
          error: "server_error",
          message: "Unable to complete reservation. Please try again.",
        },
        500
      );
    }

    // ── Map database function errors to HTTP responses ────────────────
    if (data?.error) {
      const errorMap: Record<string, { status: number; message: string }> = {
        seat_not_found: {
          status: 404,
          message: "Seat not found.",
        },
        seat_not_available: {
          status: 400,
          message: "This seat is not currently available.",
        },
        seat_already_reserved: {
          status: 409,
          message:
            "This seat has already been reserved. Please choose another.",
        },
        pricing_not_found: {
          status: 404,
          message: "Pricing is not available for this time block.",
        },
        hotel_not_found: {
          status: 404,
          message: "Hotel not found.",
        },
        server_error: {
          status: 500,
          message: "Unable to complete reservation. Please try again.",
        },
      };

      const mapped = errorMap[data.error] || {
        status: 500,
        message: "Unable to complete reservation. Please try again.",
      };

      return jsonResponse(
        { error: data.error, message: mapped.message },
        mapped.status
      );
    }

    // ── Success ──────────────────────────────────────────────────────
    return jsonResponse(
      {
        reservation_id: data.reservation_id,
        price_cents: data.price_cents,
        currency: data.currency,
      },
      200
    );
  } catch (err) {
    console.error("Edge function error:", err);
    return jsonResponse(
      {
        error: "server_error",
        message: "Unable to complete reservation. Please try again.",
      },
      500
    );
  }
});
