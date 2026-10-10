import os
import time
from pathlib import Path
from datetime import datetime, timezone, timedelta

import firebase_admin
from firebase_admin import credentials, firestore
from google.cloud.firestore_v1.base_query import FieldFilter
from twilio.rest import Client
from dotenv import load_dotenv

BASE_DIR = Path(__file__).resolve().parent
load_dotenv(BASE_DIR / ".env")

ACCOUNT_SID = os.environ["TWILIO_ACCOUNT_SID"]
AUTH_TOKEN = os.environ["TWILIO_AUTH_TOKEN"]
WHATSAPP_FROM = "whatsapp:+14155238886"

SERVICE_KEY = BASE_DIR / "serviceAccountKey.json"

if not SERVICE_KEY.exists():
    raise FileNotFoundError(
        f"Missing Firebase service account key: {SERVICE_KEY}"
    )

if not firebase_admin._apps:
    firebase_admin.initialize_app(
        credentials.Certificate(str(SERVICE_KEY))
    )

db = firestore.client()
twilio = Client(ACCOUNT_SID, AUTH_TOKEN)


def as_utc(value):
    if value.tzinfo is None:
        return value.replace(tzinfo=timezone.utc)
    return value.astimezone(timezone.utc)


def get_contacts(owner_id, trip_id):
    query = (
        db.collection("trustedContacts")
        .where(filter=FieldFilter("ownerId", "==", owner_id))
        .where(filter=FieldFilter("tripId", "==", trip_id))
    )

    phones = []

    for doc in query.stream():
        contact = doc.to_dict()

        if (
            contact.get("consentStatus") != "approved"
            or not contact.get("phone")
        ):
            continue

        phone = contact["phone"].strip()

        if phone.startswith("whatsapp:"):
            phone = phone[len("whatsapp:"):]

        if phone not in phones:
            phones.append(phone)

    return phones


def send_whatsapp(phone, body):
    recipient = phone.strip()

    if not recipient.startswith("whatsapp:"):
        recipient = f"whatsapp:{recipient}"

    return twilio.messages.create(
        from_=WHATSAPP_FROM,
        to=recipient,
        body=body,
    )


def notify_completed_checkins():
    query = (
        db.collection("checkIns")
        .where(filter=FieldFilter("status", "==", "completed"))
        .where(
            filter=FieldFilter(
                "arrivalNotificationStatus", "==", "pending"
            )
        )
    )

    for doc in query.stream():
        checkin = doc.to_dict()

        actual_time = checkin.get("actualTime")
        scheduled_time = checkin.get("scheduledTime")
        owner_id = checkin.get("ownerId")
        trip_id = checkin.get("tripId")

        if not actual_time or not scheduled_time or not owner_id or not trip_id:
            continue

        trip_snapshot = db.collection("trips").document(trip_id).get()

        if not trip_snapshot.exists:
            continue

        trip = trip_snapshot.to_dict()

        phones = get_contacts(owner_id, trip_id)

        if not phones:
            print(f"No trusted contact for trip {trip_id}", flush=True)
            continue

        actual_time = as_utc(actual_time)
        scheduled_time = as_utc(scheduled_time)

        label = checkin.get("label", "checkpoint")

        if actual_time <= scheduled_time:
            body = (
                f"JourneyCheck: The traveler reached '{label}' ON TIME. "
                "Their check-in was recorded successfully."
            )
        else:
            body = (
                f"JourneyCheck: The traveler checked in at '{label}', "
                "but after the scheduled time."
            )

        sent_to = set(checkin.get("arrivalNotificationSentTo", []))
        failures = []

        for phone in phones:
            if phone in sent_to:
                continue

            try:
                message = send_whatsapp(phone, body)

                doc.reference.update({
                    "arrivalNotificationSentTo": firestore.ArrayUnion(
                        [phone]
                    ),
                    "arrivalNotificationSid": message.sid,
                })

                sent_to.add(phone)

                print(
                    f"Arrival message submitted to {phone}: {message.sid}",
                    flush=True,
                )

            except Exception as error:
                failures.append(phone)
                print(
                    f"Arrival message failed for {phone}: {error}",
                    flush=True,
                )

        if all(phone in sent_to for phone in phones):
            doc.reference.update({
                "arrivalNotificationStatus": "sent",
                "arrivalNotificationSentAt": firestore.SERVER_TIMESTAMP,
            })
        else:
            doc.reference.update({
                "arrivalNotificationStatus": "pending",
            })


def notify_overdue_checkins():
    now = datetime.now(timezone.utc)

    query = (
        db.collection("checkIns")
        .where(filter=FieldFilter("status", "==", "pending"))
        .where(
            filter=FieldFilter("escalationStatus", "==", "pending")
        )
        .where(filter=FieldFilter("scheduledTime", "<=", now))
    )

    for doc in query.stream():
        checkin = doc.to_dict()

        scheduled = checkin.get("scheduledTime")
        owner_id = checkin.get("ownerId")
        trip_id = checkin.get("tripId")

        if not scheduled or not owner_id or not trip_id:
            continue

        # Re-read to avoid sending an overdue alert if the traveler
        # checked in after the query was executed.
        latest_snapshot = doc.reference.get()

        if not latest_snapshot.exists:
            continue

        checkin = latest_snapshot.to_dict()

        if (
            checkin.get("status") != "pending"
            or checkin.get("escalationStatus") != "pending"
        ):
            continue

        trip_ref = db.collection("trips").document(trip_id)
        trip_snapshot = trip_ref.get()

        if not trip_snapshot.exists:
            continue

        trip = trip_snapshot.to_dict()

        if trip.get("status") != "active":
            continue

        grace = int(trip.get("gracePeriodMinutes", 1))
        deadline = as_utc(scheduled) + timedelta(minutes=grace)

        if now < deadline:
            continue

        phones = get_contacts(owner_id, trip_id)

        if not phones:
            print(f"No trusted contact for trip {trip_id}", flush=True)
            continue

        body = (
            f"JourneyCheck safety alert: The traveler missed "
            f"'{checkin.get('label', 'checkpoint')}'. "
            f"Destination: {trip.get('destination', 'Not specified')}. "
            "Please contact the traveler and check they are safe."
        )

        sent_to = set(checkin.get("overdueNotificationSentTo", []))

        for phone in phones:
            if phone in sent_to:
                continue

            try:
                message = send_whatsapp(phone, body)

                doc.reference.update({
                    "overdueNotificationSentTo": firestore.ArrayUnion(
                        [phone]
                    ),
                    "notificationSid": message.sid,
                })

                sent_to.add(phone)

                print(
                    f"Overdue alert submitted to {phone}: {message.sid}",
                    flush=True,
                )

            except Exception as error:
                print(
                    f"Overdue alert failed for {phone}: {error}",
                    flush=True,
                )

        if all(phone in sent_to for phone in phones):
            doc.reference.update({
                "escalationStatus": "overdue_sent",
                "notificationSentAt": firestore.SERVER_TIMESTAMP,
            })


if __name__ == "__main__":
    print("JourneyCheck WhatsApp worker running. Checking every 30 seconds.")

    while True:
        try:
            notify_completed_checkins()
            notify_overdue_checkins()

        except Exception as error:
            print(f"Worker error: {error}", flush=True)

            if "429" in str(error) or "quota" in str(error).lower():
                print("Firestore quota reached. Waiting 2 minutes.", flush=True)
                time.sleep(120)
                continue

        time.sleep(30)