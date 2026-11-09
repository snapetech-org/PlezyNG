# BookOrbit in Pleazyng and SeerrNG

BookOrbit can receive new book requests from SeerrNG and serve its library
directly to Pleazyng. These connections are independent: SeerrNG uses a
dedicated requester account, while each Pleazyng user signs in to BookOrbit
with their own account and sees only books that account may access.

## Request a missing title

1. In SeerrNG, an administrator opens **Settings → Services → Book Acquisition
   Services**, selects **Add BookOrbit Server**, enters a BookOrbit account
   with Request books permission, tests the connection, and marks it as the
   default for ebooks, audiobooks, or both. Enable its library scan to publish
   imported file availability.
2. Configure approval, indexers, download clients, and import automation in
   BookOrbit. Without auto approval, requests wait there for a decision after
   SeerrNG approval. The two apps display that state separately.
3. In Pleazyng, connect SeerrNG under **Settings → Services → Seerr**. Open
   **Requests**, choose **Ebooks** or **Audiobooks**, and request a title.
   SeerrNG owns authorization, quotas, service routing, and final status.

Both formats can share one BookOrbit service. SeerrNG uses BookOrbit's paired
request API for a title requested in both formats. A BookOrbit service account
owns those requests; this integration does not represent a SeerrNG user as a
BookOrbit user without an explicit identity link.

## Read and listen to your library

Open **Sources → Add Source → BookOrbit**. Enter the HTTPS address of your
BookOrbit instance and your BookOrbit username and password. An HTTP address
can be enabled explicitly for a trusted local network. Pleazyng keeps the
credentials in its encrypted profile vault and holds the bearer token only in
memory. Source setup tests the sign-in and library before saving.

The source browses and searches BookOrbit's books, displays covers, opens
ebook and comic files, streams audiobook assets, and synchronizes audiobook
progress with the signed-in BookOrbit account. Pleazyng's reading position
remains local: BookOrbit's file-progress write endpoint requires its own app
attestation and does not accept a third-party reader token. Downloads and
offline reading continue through Pleazyng's source library.

If a title is pending, review its request in SeerrNG and the BookOrbit queue.
The direct Pleazyng source shows imported library files; it does not show
pending BookOrbit acquisitions as playable entries. A library scan in SeerrNG
and a refresh in Pleazyng pick up an imported file.
