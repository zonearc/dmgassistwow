# Translations

Player-facing text is keyed by its English wording (`L["..."]`). Each language lives in `tools/i18n/<locale>.txt`
as `<index>\t<translation>` lines, indexing `keys.json`; `build_locales.py` turns them into
`addons/DMGAssist/Locales/<locale>.lua` and refuses a translation that drops a `%s` / `%d` or a colour code.
A line with no translation shows in English.

When you add or change text:

```bash
lua tools/i18n/record_strings.lua /tmp/runtime.txt          # strings the settings pages and welcome look up
python3 tools/i18n/extract_strings.py /tmp/runtime.txt /tmp/keys.json   # plus every L["..."] in the code
```

Compare `/tmp/keys.json` with `tools/i18n/keys.json`, add the new lines at the end of `keys.json` (indexes of
existing lines must not move), translate them in every `<locale>.txt`, then run:

```bash
python3 tools/i18n/build_locales.py
```

Spanish (Latin America) uses the Spanish file. Corrections from native speakers are welcome: edit the `.txt`.
