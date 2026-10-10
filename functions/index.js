const { onDocumentUpdated } = require("firebase-functions/v2/firestore");
const { onSchedule } = require("firebase-functions/v2/scheduler");
const { defineSecret } = require("firebase-functions/params");
const { setGlobalOptions } = require("firebase-functions");
const logger = require("firebase-functions/logger");
const admin = require("firebase-admin");
const crypto = require("crypto");

admin.initializeApp();

const db = admin.firestore();
const resendApiKey = defineSecret("RESEND_API_KEY");

// Change this to the sender address configured in your Resend account.
const FROM_EMAIL = "JourneyCheck <notifications@your-verified-domain.com>";

setGlobalOptions({
    region: "asia-south1",
    maxInstances: 5,
});

function escapeHtml(value) {
    return String(value ?? "").replace(/[&<>"']/g, (character) => {
        const entities = {
            "&": "&amp;",
            "<": "&lt;",
            ">": "&gt;",
            '"': "&quot;",
            "'": "&#39;",
        };
        return entities[character];
    });
}

function formatDate(value) {
    if (!value) return "Not available";

    const date =
        typeof value.toDate === "function" ? value.toDate() : new Date(value);

    if (Number.isNaN(date.getTime())) return "Not available";

    return new Intl.DateTimeFormat("en-IN", {
        dateStyle: "medium",
        timeStyle: "short",
        timeZone: "Asia/Kolkata",
    }).format(date);
}

function idempotencyKey(value) {
    return crypto.createHash("sha256").update(value).digest("hex");
}

async function sendEmail({ to, subject, html, idempotency }) {
    const apiKey = resendApiKey.value();

    if (!apiKey) {
        throw new Error("RESEND_API_KEY is not configured.");
    }

    if (FROM_EMAIL.includes("your-verified-domain.com")) {
        throw new Error(
            "Update FROM_EMAIL in functions/index.js to your verified Resend sender."
        );
    }

    const response = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: {
            Authorization: `Bearer ${apiKey}`,
            "Content-Type": "application/json",
            "Idempotency-Key": idempotencyKey(idempotency),
        },
        body: JSON.stringify({
            from: FROM_EMAIL,
            to: [to],
            subject,
            html,
        }),
    });

    const responseText = await response.text();

    if (!response.ok) {
        throw new Error(
            `Resend API error (${response.status}): ${responseText}`
        );
    }

    return responseText ? JSON.parse(responseText) : {};
}

async function getApprovedContacts(ownerId, tripId) {
    const snapshot = await db
        .collection("trustedContacts")
        .where("ownerId", "==", ownerId)
        .where("tripId", "==", tripId)
        .get();

    const seen = new Set();
    const contacts = [];

    for (const document of snapshot.docs) {
        const contact = document.data();
        const email = String(contact.email ?? "").trim().toLowerCase();

        if (
            contact.consentStatus === "approved" &&
            /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) &&
            !seen.has(email)
        ) {
            seen.add(email);
            contacts.push({ email, id: document.id });
        }
    }

    return contacts;
}

async function sendToApprovedContacts({
    contacts,
    subject,
    html,
    eventKey,
}) {
    for (const contact of contacts) {
        await sendEmail({
            to: contact.email,
            subject,
            html,
            idempotency: `${eventKey}:${contact.email}`,
        });

        logger.info("JourneyCheck email accepted by Resend", {
            contactId: contact.id,
            eventKey,
        });
    }
}

/**
 * Email trusted contacts when a check-in transitions to completed.
 */
exports.notifyCheckInCompleted = onDocumentUpdated(
    {
        document: "checkIns/{checkInId}",
        secrets: [resendApiKey],
        retry: true,
    },
    async (event) => {
        const before = event.data.before.data();
        const after = event.data.after.data();

        if (before.status === "completed" || after.status !== "completed") {
            return;
        }

        const ownerId = after.ownerId;
        const tripId = after.tripId;

        if (!ownerId || !tripId) {
            logger.error("Completed check-in has no ownerId or tripId", {
                checkInId: event.params.checkInId,
            });
            return;
        }

        const tripSnapshot = await db.collection("trips").doc(tripId).get();

        if (!tripSnapshot.exists) {
            logger.warn("Trip not found for completed check-in", { tripId });
            return;
        }

        const trip = tripSnapshot.data();

        if (trip.ownerId !== ownerId) {
            logger.error("Trip owner does not match check-in owner", { tripId });
            return;
        }

        const contacts = await getApprovedContacts(ownerId, tripId);

        if (contacts.length === 0) {
            logger.info("No approved trusted contacts for check-in", {
                checkInId: event.params.checkInId,
            });
            return;
        }

        const destination = escapeHtml(trip.destination || "your destination");
        const checkInLabel = escapeHtml(after.label || "Safety check-in");
        const completedAt = formatDate(after.actualTime || new Date());

        const html = `
      <div style="font-family:Arial,sans-serif;max-width:600px;margin:auto">
        <h2 style="color:#16803c">JourneyCheck: Check-in completed</h2>
        <p>The traveler has successfully completed a scheduled safety check-in.</p>
        <p><strong>Destination:</strong> ${destination}</p>
        <p><strong>Check-in:</strong> ${checkInLabel}</p>
        <p><strong>Completed at:</strong> ${escapeHtml(completedAt)}</p>
        <p>This is an automated notification from JourneyCheck.</p>
      </div>`;

        await sendToApprovedContacts({
            contacts,
            subject: "JourneyCheck: Traveler checked in successfully",
            html,
            eventKey: `checkin-completed-${event.params.checkInId}`,
        });
    }
);

/**
 * Every five minutes, find pending check-ins whose grace period has expired.
 */
exports.checkOverdueCheckIns = onSchedule(
    {
        schedule: "every 5 minutes",
        timeZone: "Asia/Kolkata",
        secrets: [resendApiKey],
        timeoutSeconds: 120,
    },
    async () => {
        const now = admin.firestore.Timestamp.now();

        const snapshot = await db
            .collection("checkIns")
            .where("status", "==", "pending")
            .where("scheduledTime", "<=", now)
            .orderBy("scheduledTime", "asc")
            .limit(100)
            .get();

        for (const checkInDoc of snapshot.docs) {
            const checkIn = checkInDoc.data();

            if (
                checkIn.escalationStatus &&
                checkIn.escalationStatus !== "pending"
            ) {
                continue;
            }

            const ownerId = checkIn.ownerId;
            const tripId = checkIn.tripId;

            if (!ownerId || !tripId || !checkIn.scheduledTime) {
                logger.warn("Skipping incomplete check-in document", {
                    checkInId: checkInDoc.id,
                });
                continue;
            }

            const tripRef = db.collection("trips").doc(tripId);
            const tripSnapshot = await tripRef.get();

            if (!tripSnapshot.exists) continue;

            const trip = tripSnapshot.data();

            if (trip.ownerId !== ownerId || trip.status !== "active") {
                continue;
            }

            const gracePeriodMinutes = Number(
                trip.gracePeriodMinutes ?? trip.graceMinutes ?? 10
            );

            const scheduledDate = checkIn.scheduledTime.toDate();
            const overdueAt = new Date(
                scheduledDate.getTime() + Math.max(0, gracePeriodMinutes) * 60 * 1000
            );

            if (overdueAt.getTime() > Date.now()) continue;

            const contacts = await getApprovedContacts(ownerId, tripId);

            if (contacts.length === 0) {
                logger.info("No approved contacts for overdue check-in", {
                    checkInId: checkInDoc.id,
                });
                continue;
            }

            // Claim the event transactionally to avoid concurrent scheduled runs
            // sending the same overdue notification.
            const claimed = await db.runTransaction(async (transaction) => {
                const freshSnapshot = await transaction.get(checkInDoc.ref);

                if (!freshSnapshot.exists) return false;

                const fresh = freshSnapshot.data();

                if (
                    fresh.status !== "pending" ||
                    (fresh.escalationStatus &&
                        fresh.escalationStatus !== "pending")
                ) {
                    return false;
                }

                transaction.update(checkInDoc.ref, {
                    escalationStatus: "processing",
                });

                return true;
            });

            if (!claimed) continue;

            try {
                const destination = escapeHtml(trip.destination || "the destination");
                const label = escapeHtml(checkIn.label || "Safety check-in");

                const html = `
          <div style="font-family:Arial,sans-serif;max-width:600px;margin:auto">
            <h2 style="color:#b42318">JourneyCheck: Overdue safety check-in</h2>
            <p>A traveler has not completed a scheduled safety check-in within the expected time.</p>
            <p><strong>Destination:</strong> ${destination}</p>
            <p><strong>Check-in:</strong> ${label}</p>
            <p><strong>Scheduled time:</strong> ${escapeHtml(formatDate(checkIn.scheduledTime))}</p>
            <p><strong>Grace period:</strong> ${gracePeriodMinutes} minutes</p>
            <p>Please try contacting the traveler to confirm their safety.</p>
            <p>This alert does not necessarily mean the traveler is in danger.</p>
          </div>`;

                await sendToApprovedContacts({
                    contacts,
                    subject: "JourneyCheck safety alert: Check-in overdue",
                    html,
                    eventKey: `checkin-overdue-${checkInDoc.id}`,
                });

                await db.runTransaction(async (transaction) => {
                    const freshSnapshot = await transaction.get(checkInDoc.ref);
                    if (!freshSnapshot.exists) return;

                    const fresh = freshSnapshot.data();

                    if (fresh.escalationStatus !== "processing") return;

                    transaction.update(checkInDoc.ref, {
                        escalationStatus: "overdue_sent",
                        overdueAt: admin.firestore.FieldValue.serverTimestamp(),
                    });

                    const alertRef = db.collection("alerts").doc(
                        `overdue_${checkInDoc.id}`
                    );

                    transaction.set(alertRef, {
                        ownerId,
                        tripId,
                        checkInId: checkInDoc.id,
                        type: "overdue",
                        message: "A scheduled safety check-in is overdue.",
                        createdAt: admin.firestore.FieldValue.serverTimestamp(),
                        status: "sent",
                    });
                });

                logger.info("Overdue notification processing completed", {
                    checkInId: checkInDoc.id,
                });
            } catch (error) {
                logger.error("Failed to process overdue notification", {
                    checkInId: checkInDoc.id,
                    error: error.message,
                });

                // Permit a later scheduled run to retry after a failure.
                await checkInDoc.ref.update({
                    escalationStatus: "pending",
                });
            }
        }
    }
);
