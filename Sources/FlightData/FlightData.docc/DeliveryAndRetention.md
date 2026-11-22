# Delivery and retention

How the container keeps reports on the device, when it sends them, and when it gives one up.

## Overview

A report is sealed before it is kept: what is on the device is what goes to the server. The container keeps
its files in `Application Support/<bundle ID>/FlightData/`, in a folder of their own for each app token, left
out of device backups. A report that was queued is sent from that device or not at all.

### When reports are sent

The container tries to send what is waiting:

- just after a report is submitted, and when a period ends
- when it is made, which sends what an earlier launch left
- when an iOS app becomes active again, and when the network comes back
- when a wait it set itself is over

``FlightDataContainer/deliverPending()`` does the same at once, for an app that wants to send before it does
something else. Reports are sent oldest first, one at a time.

### What the server's answer does

| The server | The report |
|---|---|
| Takes it, and says so with `"received": true` | Is removed |
| Answers with a success but without saying it received it, as a captive portal's page does | Is sent again |
| Refuses it as it is: 400, 409, 413, 415 or 422 | Is deleted, and the kit logs why |
| Requires a proof of a genuine copy, which this device can’t give | Is deleted, and the kit logs why |
| Is busy, limited or down, or asks to wait: 408, 429, 5xx, or another refusal | Waits, and is sent again |
| Can't be reached | Waits, and is sent again |

A report that waits is tried again when the server said, with `Retry-After`, up to a day later. Otherwise it
waits 30 seconds after the first failure, doubling up to six hours. When the server couldn't be reached at all,
the network coming back or the app becoming active ends that wait early, but not within five seconds of the
last attempt.

### Offline and across launches

Nothing is lost by going offline or quitting: a queued report waits on disk, and the next container sends it.
A report still unsent 30 days after it was queued is deleted. When a report or the kit's folder can't be read
or written, as can happen before an iOS device's first unlock, the container tries again from 30 seconds,
doubling up to six hours, until it can.

### In the background

On iOS, a delivery that is running when the app goes to the background goes on for the time the system allows.
If that runs out, the upload in flight is cancelled and its report stays queued, as if it had not been tried.
On the Mac, delivery runs whenever the app does.

### Periodic reports

What a periodic type gathers is kept in memory as events are recorded, and saved a few seconds after the last
change, and at once when the app resigns active, goes to the background or quits. An app that is stopped in
those few seconds loses the events since the last save.

When the period ends, the gathered report is sealed and queued like any other; when the app wasn't running at
the end of the period, that happens the next time it runs. A report a type can no longer make, because the
app's update changed its `Codable` form, is deleted and logged. What a type removed from the schema had
gathered is kept for 30 days, in case an update brings the type back.

### Proving the copy is genuine

Where App Attest is available, the container proves that each report comes from a genuine copy of the app,
signed by the developer, on a real device: it enrolls a key with the server the first time it sends, and signs
each report together with a challenge the server gives for it. When the server is busy or can't be reached for
a challenge, the report waits; when it gives no challenge for another reason, the report goes without a proof.

### Logs

The kit logs, under the subsystem `dev.flightdata.kit`, each report it deletes and why, and what it couldn't
save. It logs report IDs, channel names and reasons, never what a report says.
