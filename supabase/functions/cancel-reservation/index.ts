import { serve } from "https://deno.land/std@0.177.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.39.3";
import Stripe from "https://esm.sh/stripe@14.11.0?target=deno";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function isValidUUID(str: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
    str
  );
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const { cancellation_token } = await req.json();

    if (!cancellation_token) {
      return jsonResponse({
        error: "missing_fields",
        message: "Cancellation token is required.",
      });
    }

    if (
      typeof cancellation_token !== "string" ||
      !isValidUUID(cancellation_token)
    ) {
      return jsonResponse({
        error: "invalid_token",
        message: "Invalid cancellation token.",
      });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabase = createClient(supabaseUrl, serviceRoleKey);

    // ── 1. Check eligibility (read-only) ──
    const { data: eligibility, error: rpcError } = await supabase.rpc(
      "fn_check_cancellation_eligibility",
      { p_cancellation_token: cancellation_token }
    );

    if (rpcError) {
      console.error("RPC error:", rpcError);
      return jsonResponse({
        error: "server_error",
        message: "Unable to process cancellation. Please try again.",
      });
    }

    if (eligibility?.error) {
      const errorMap: Record<string, string> = {
        reservation_not_found: "Reservation not found.",
        reservation_not_cancellable:
          "This reservation has already been cancelled.",
        reservation_expired: "This reservation has expired.",
        cancellation_window_closed:
          "The cancellation window has closed. Cancellations must be made at least 2 hours before your reservation.",
      };

      return jsonResponse({
        error: eligibility.error,
        message:
          errorMap[eligibility.error] ||
          "Unable to process cancellation. Please try again.",
      });
    }

    // ── 2. Issue Stripe refund (if real payment) ──
    const stripePaymentIntentId = eligibility.stripe_payment_intent_id;
    let refundAmountCents = 0;

    if (stripePaymentIntentId && eligibility.payment_status === "succeeded") {
      const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");
      if (!stripeSecretKey) {
        console.error("STRIPE_SECRET_KEY not set");
        return jsonResponse({
          error: "refund_failed",
          message:
            "Unable to process refund. Please contact the front desk.",
        });
      }

      const stripe = new Stripe(stripeSecretKey, {
        apiVersion: "2023-10-16",
        httpClient: Stripe.createFetchHttpClient(),
      });

      try {
        const refund = await stripe.refunds.create({
          payment_intent: stripePaymentIntentId,
        });

        if (refund.status === "failed") {
          console.error("Stripe refund status: failed", refund);
          return jsonResponse({
            error: "refund_failed",
            message:
              "Unable to process refund. Please contact the front desk.",
          });
        }

        refundAmountCents = eligibility.price_cents;
      } catch (stripeErr) {
        console.error("Stripe refund error:", stripeErr);
        return jsonResponse({
          error: "refund_failed",
          message:
            "Unable to process refund. Please contact the front desk.",
        });
      }
    } else {
      // Mock reservation (no stripe_payment_intent_id) — mark as refunded with 0
      refundAmountCents = eligibility.price_cents;
    }

    // ── 3. Update reservation (only after Stripe succeeds or mock) ──
    const { error: updateError } = await supabase
      .from("reservations")
      .update({
        payment_status: "refunded",
        cancelled_at: new Date().toISOString(),
        cancellation_reason: "guest_cancelled",
        refund_amount_cents: refundAmountCents,
      })
      .eq("id", eligibility.reservation_id);

    if (updateError) {
      console.error("Update error:", updateError);
      // Stripe refund was issued but DB update failed — log for manual reconciliation
      return jsonResponse({
        error: "server_error",
        message:
          "Your refund was processed but we encountered an error updating your reservation. Please contact the front desk.",
      });
    }

    return jsonResponse({
      reservation_id: eligibility.reservation_id,
      seat_label: eligibility.seat_label,
      reservation_date: eligibility.reservation_date,
      time_block: eligibility.time_block,
      price_cents: eligibility.price_cents,
      refund_amount_cents: refundAmountCents,
      currency: eligibility.currency,
    });
  } catch (err) {
    console.error("Edge function error:", err);
    return jsonResponse({
      error: "server_error",
      message: "Unable to process cancellation. Please try again.",
    });
  }
});
