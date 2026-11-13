# Legacy database import localization QA

This addendum covers the 21 `startup.legacyImport*` messages for the explicit
first-run desktop database import. English is the source. The 32 non-English
base locales contain assistant-generated draft translations; `es-419`, `fr-CA`,
`pt-BR` and `pt-PT` inherit from their configured language parents.

Each draft is recorded as `assistant-generated-draft` in
`docs/localization/provenance/`. The source strings are recorded as
`source-english`. No independent semantic review or native-speaker review has
been completed. Pleazyng database identity, separate server credentials,
download-path portability, and rollback-copy wording are especially important
to review with fluent speakers before claiming language quality. These drafts
do not establish accessibility or store/device qualification.

The translations preserve the `${name}`, `${size}`, `${version}` and `${count}`
placeholders. Regional locales inherit the new strings without adding duplicate
entries. The batch adds no English fallback keys and does not increase the
English fallback budget.

`check_localizations.py` verifies catalog coverage, placeholders and inheritance
for all 37 locales; it does not assess fluency. Run `clean_translations.py
--check --strict` for translation hygiene. The English source hash checkpoint
records the current source strings and does not mark these translations as
reviewed.
