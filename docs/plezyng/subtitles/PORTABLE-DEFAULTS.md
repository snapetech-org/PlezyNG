# Portable caption defaults

App overlay controls and subtitle-role preferences now open **Transfer saved
caption defaults**. Export creates a small versioned JSON document containing
the saved appearance of both app-caption lanes and the current profile's
default forced/SDH role preferences. An unset lane exports the renderer's
effective default appearance. Unsaved active-overlay edits are not substituted
for saved defaults.

Opening a file only previews it. Each lane shows every current/incoming field,
and the role group shows both choices. Importing one group is an explicit local
write for the active profile. It does not replace other groups, title overrides
or currently displayed captions. Appearance applies on later attachment;
role defaults participate in later automatic selection under the established
manual/server/Off priority rules.

The document has no profile, account, server, source or title identifiers,
caption text, media, timing corrections, pairing codes or binary fonts. It is
plain JSON, intended for the user's own file transfer. A font family digest can
refer to an imported font, but the file does not install it; missing imported
fonts continue to use the bundled fallback. Font licensing/installation uses
the existing separate font workflow. Native renderer settings are separate.

The reader caps the file at 16 KiB, requires exactly two lanes and known schema
fields, checks every numeric bound/color/Boolean/layout/role, and accepts only
known family names or bounded imported-font digest identifiers. Streams have
inactivity and total read-time bounds. Unsupported fields are rejected rather
than silently running commands or applying arbitrary preferences.

Appearance saves now share a serialized write queue, preserving the other lane
when two saves overlap. Import compares the selected group's current value
with its preview inside that queue; subtitle-role writes do the same in their
existing queue. A concurrent change refuses overwrite and asks for a fresh
preview. Each group commits separately, so there is no partially successful
three-group transaction presented as one success. Profile changes invalidate
the operation. This provides deliberate conflict handling for file transfer,
not background cloud synchronization of preferences.

No tests, analyzer, formatter, build, file-picker run or device qualification
was performed in the code-only pass. Runtime behavior remains unqualified.
