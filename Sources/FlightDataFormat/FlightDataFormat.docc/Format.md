# The sealed report format

How a report is sealed, how its files are packed, and what is sent. Everything here is implemented in this
module. The format is version 1 and may still change before FlightDataKit 1.0.

## Keys and encryption

Use HPKE base mode with X25519, HKDF-SHA256, and ChaCha20-Poly1305. The HPKE `info` bytes are
UTF-8 `dev.flightdata.report.v1`. Create a fresh sender for every envelope and encrypt exactly
one message with that sender. Text and payload therefore have independent encapsulated keys.

The public key string is `fdpk2_` followed by unpadded base64url of 36 bytes: the 32 raw X25519
public-key bytes, then a 4-byte checksum, the first four bytes of SHA-256 of `fdpk2` (UTF-8)
followed by the 32 key bytes. 54 ASCII bytes in all. A mistyped key fails its checksum and is
refused, instead of sealing reports to a key nobody holds. Parsing rejects other prefixes, padding,
whitespace, invalid characters, wrong lengths, a wrong checksum and noncanonical encodings. An
encoded key may still be unusable for key agreement; sealing rejects such a key.

A private key moves between tools as PKCS#8 PEM (RFC 8410): `-----BEGIN PRIVATE KEY-----`, the
base64 of the 16 DER bytes `302e020100300506032b656e04220420` and the 32 raw private-key bytes,
then `-----END PRIVATE KEY-----`. OpenSSL reads and writes the same form
(`openssl genpkey -algorithm X25519`).

The key ID is the first eight bytes of SHA-256 of the raw public key, displayed as 16 lowercase
hex digits. It selects a candidate key; it is not a substitute for decryption/authentication.

## Envelope layout

| Offset | Bytes | Meaning |
|---|---|---|
| 0 | 4 | ASCII `FDR1` |
| 4 | 8 | Raw key ID bytes |
| 12 | 32 | HPKE encapsulated key |
| 44 | Remaining | Ciphertext followed by its 16-byte authentication tag |

The overhead is 60 bytes. Associated data is the report UUID in canonical lowercase hyphenated
form, followed by `/sealed` for text or `/payload` for attachments, encoded as UTF-8. Supplying
a different report UUID or part fails authentication. App verification is a separate operation;
HPKE base mode does not prove which application sent the report.

## Size bounds

The `sealed` field is standard padded base64 of the text envelope: at most 48,000 ASCII bytes, so a text
envelope may hold at most 36,000 bytes, header and tag included, and the text at most 35,940. A payload
envelope may contain at most 10,000,000 bytes and packed plaintext at most 9,999,940 bytes. Limits apply
before expensive cryptographic work where possible. The limits on each part of the text do not add up to this
budget, so the encoded text is also checked against it when a report is validated, before anything is sealed.

A report's files are bounded together by one number, 10,000,000 bytes of
content, which is also the payload envelope's bound; packing checks the final payload bound as well, so
files that don't compress may need a little less. Never silently truncate a report to fit.

Opening rejects oversized or truncated envelopes, unsupported magic, a mismatched key ID,
invalid encapsulated keys, authentication failures, and altered/trailing ciphertext. Errors
do not return partially decrypted content. Archive extraction requires its own bounded parser;
successful envelope authentication is not proof that an archive is safe.

## Test vectors

`Tests/Resources/envelopes.json` holds a synthetic private key, report UUID, public key and key ID,
and two envelopes sealed with them: one of text and one of binary payload bytes. They were made once
with CryptoKit, apart from the `Envelope` type, and the tests open them as they are. The payload vector
tests opening only; it is not a valid payload archive. The key exists only for these tests.

The tests also open RFC 9180's own vectors for this suite (appendix A.2.1, base mode) with the HPKE
the envelopes use. The vectors catch a change in how envelopes open; they are not a cryptographic audit.

## Payload archive

A report's attachments travel as one sealed payload. The plaintext is a gzip stream (RFC 1952) of a
POSIX ustar archive. The gzip header carries no time and no name, so the same files always pack to the
same bytes.

The first entry is `manifest.json`, UTF-8 JSON with sorted keys:

```json
{"files":[{"bytes":6,"content_type":"text/xml","path":"document.cdxml","sha256":"…"}],
 "format":"dev.flightdata.payload","version":1}
```

Every other entry is a regular file named by a manifest `path`, in manifest order. A path is flat: 1 to
100 UTF-8 bytes, no `/`, `\` or NUL byte, no control or formatting character (such as a right-to-left
override), not `.` or `..`, not `manifest.json`, and distinct within the
archive. The writer checks uniqueness and the reserved manifest name without regard to case; a reader
may still meet two paths that differ only in case, and must keep both if it writes them to a
case-insensitive volume. An archive holds up to 1,000 files with at most 10,000,000 bytes of file
content in total. Tar entries use mode 0644
and time zero. The packed archive must fit the payload bound (9,999,940 bytes before sealing), so
incompressible attachments near the content limit are refused rather than cut.

Unpacking is its own bounded parser. It refuses a gzip header with reserved flags, a bad CRC or length
trailer, output past the content limit plus 2 MiB of tar and manifest overhead (so a small archive
can't expand without limit), any entry that is not a regular file, a bad tar checksum, a long name, more
than 1,001 entries, anything but zero padding after the end marker, a first entry other than the manifest,
a different format name or version, files whose content passes 10,000,000 bytes in total, and any file whose
name, size or SHA-256 differs from the manifest. It reads the gzip header's optional extra field, name,
comment and header CRC, which it checks. The system `tar`, `gzip` and `gunzip` read what the kit writes, and the kit reads what `gzip` writes.

## Report on the wire

`POST /v1/reports` is `multipart/form-data`. The `report` part is JSON with exactly `id` (lowercase UUID),
`kind` (`feedback`, `crash` or `telemetry`), `channel`, `app`, `test`, `key_id` and `sealed` (standard base64
of the text envelope). `channel` is the name the app chose to route the report by, 1–256 bytes of UTF-8
without control characters; it is readable. `key_id` names the key the envelopes are sealed to. The optional
`payload` part is the payload envelope, filename `payload.bin`. Text sealed inside is JSON of `{title, body,
contact, labels, fields, schema}`, keys sorted. `fields` holds the app's own values by key, each a string, a
number or `true`/`false`: `{"document":"Untitled 3","pro":true,"retries":3}`. `labels` are what the
developer's own tools add once a report has arrived; an app always writes an empty array.

A whole number in the signed or unsigned 64-bit range is written as a JSON integer and read back exactly. Any
other number is an IEEE 754 double, so a whole number beyond 2^53 written as a double may not be exact: send
identifiers as integers, or as text when they can exceed 64 bits.

`schema` is what the app says about the fields this report carries, so that a report describes itself and
nothing has to be declared where it is read. It is an array in the order to show them, one object for each
field the app describes that has a value here: `key`, `label`, `kind` (`text`, `integer`, `number`,
`boolean` or `choice`) and, for a choice whose value is one of its options, `option`, what that option is
called. A field is described at most once; a label has 1 to 100 characters and an option's name at most 100.
A reader keeps a `kind` it doesn't know as it is.

```json
"schema":[{"key":"area","kind":"choice","label":"Area","option":"Export"},
          {"key":"copies","kind":"integer","label":"Copies"}]
```

`schema` is left out when it would be empty, and a reader treats a missing
one as empty. A field with a value and no entry is shown by its key. Help text, whether a field is
required and a choice's other options stay in the app. Nothing the person wrote appears outside the
envelopes.

Headers: `Authorization: Ingest <app token>`, `X-Install-ID` (32 random lowercase hex characters the app
keeps) and `User-Agent: FlightDataKit/<version>`. With a proof of the app's copy, `X-Attest-Key-ID`,
`X-Attest-Challenge` and `X-Attest-Assertion` too.

## Earlier keys and text

Earlier keys and text are still read: a public key written as `fdpk1_` and the unpadded base64url of the
32 key bytes alone (49 ASCII bytes, without a checksum), and sealed text whose values are all strings,
under `metadata` in place of `fields`. Neither is written.
