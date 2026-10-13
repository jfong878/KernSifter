# TRANSLITERATION GUARDRAILS — All Freebuff Projects

**This file is the binding policy for every agent, thread, and session that touches any
project under `F:\Freebuff Projects`. It applies to all projects — whether or not they
currently contain transliterated Arabic — because any project may grow transliterated
content at any time. Every future agent must read this file first.**

---

## 1. Response Protocol

**When a user gives you an instruction in any Freebuff Projects workspace, your
first line of output MUST be:**

```
Transliteration System Acknowledged.
```

This confirms the agent has read the guardrails and is ready to act. No exceptions.

## 2. Transliteration Scheme — Single Source of Truth

The transliteration scheme originates in the **Maktabat-Abee-Ṣaaliḥ** project. It is
the authoritative reference for all consonant spellings, article folding, Taa
ul-Marbootah rules, long-vowel conventions, and technical term capitalization.

**Source of truth:** `Maktabat-Abee-Ṣaaliḥ/TRANSLITERATION.md`

Every project that contains transliterated Arabic terms MUST carry a copy of this
scheme in its own `TRANSLITERATION.md`. The copies are kept in sync by the
transliteration guardrails tool (`tools/check-transliteration.js`), which is also
copied to each project.

### Key rules (summary — see TRANSLITERATION.md for full detail)

| Rule | Spelling | Reject |
|------|----------|--------|
| Ṣaad ص | `ṣ` | `s`, `S` |
| Ḍaad ض | `ḍ` | `d`, `D` |
| Ṭaa ط | `ṭ` | `t`, `T` |
| Ḥaa ح | `ḥ` | `h` (bare) |
| DHD ظ | `dH` | `z`, `dh`, `Dh` |
| ʿAin / Hamzah | `'` (straight ASCII) | `‘` `’` (curly), `ʾ` |
| Sun letters | As-, Ash-, Ad-, etc. | Al-Shams, Al-Sabt |
| Muḍaaf article | `ul-`, `il-`, `ut-` | Al- after a construct noun |
| Taa ul-Marbootah | `-at` (Waqf: `-ah`) | Always `-ah`, always `-at` |
| Long vowels | `aa`, `ee`, `oo` | `ā`, `ī`, `ū`, `â`, `î`, `û` |
| Soorah construct | Soorat ul-Kahf | Soorah Kahf, Soorat Al-Kahf |
| Technical terms | Imaalah, Naql, Taqleel, Sakt, Ishmaam, Ikhtilaas, Yaa' ul-Iḍaafah, Yaa' Zaa'idah, Haa' al-Kinaayah | Lowercase variants |

## 3. Enforcement Policy

### For agents writing or editing content:

1. **Before writing any transliterated Arabic term**, check it against the scheme in
   `TRANSLITERATION.md`. If the term is not in the scheme, derive it by the consonant
   and article-folding rules — do not invent spellings.
2. **When adding or editing a file** that contains transliterated text, run the
   applicable check script after your edit:
   - `node tools/check-alif-laam.js` — article folding, Soorah construct, name spellings
   - `node tools/check-transliteration.js` — full transliteration corpus scan
   - `node tools/check-strict-scheme.js` — rejects any term outside the scheme
3. **Reject any transliteration that violates the scheme.** This includes:
   - Bare `h` where `ḥ` is required
   - `dh` where `dH` is required (or vice versa)
   - `Al-` before a sun letter (should be `As-`, `Ash-`, `Ad-`, etc.)
   - `Al-` after a Muḍaaf noun (should be `ul-`, `il-`, etc.)
   - `-ah` on a Taa ul-Marbootah word in Waṣl context (should be `-at`)
   - Curly apostrophes (`'` `'`) instead of straight ASCII (`'`)
   - Macrons or circumflexes (`ā`, `â`) instead of doubled vowels (`aa`)
   - Inconsistent capitalization of technical terms

### For agents reviewing content:

4. **Screenshot-based auditing**: When the user asks you to audit or guard "the entire
   Mushaf", "the whole site", or any other comprehensive scope, your audit MUST include:
   - **Screenshotting EVERYTHING** the user asked about — every page, every screen,
     every view — and analyzing each screenshot for errors.
   - Text-only code review is not sufficient when the user requests a visual audit.
   - Use the preview server and `preview_screenshot` / `preview_snapshot` tools to
     capture every page, then verify against the transliteration scheme.
5. **When the user says something is fixed or guarded**, verify by re-checking the
   specific items — do not assume the fix persisted without evidence. Check for:
   - Regression: old errors reappearing
   - Repetition: the same mistake in new locations
   - Drift: a correct spelling reverting to an incorrect form

## 4. Projects Currently Under This Policy

| Project | Transliterated Arabic | TRANSLITERATION.md | tools/check-transliteration.js |
|---------|----------------------|--------------------|--------------------------------|
| Maktabat-Abee-Ṣaaliḥ | ✓ | ✓ | ✓ |
| Anṣaar-us-Sunnah-International-Waqf | ✓ | ✓ | ✓ |
| Project-Kashshaaf | — | — | — |
| Bazaar | — | — | — |
| KernSifter | — | — | — |
| freebuff | — | — | — |
| yt-dlp | — | — | — |

Projects marked "—" do not currently use transliterated Arabic but MUST still observe
this policy: if they ever add transliterated content, it must conform to the scheme.

## 5. Syncing the Scheme

To propagate a change to the transliteration scheme across all projects:

1. Edit `Maktabat-Abee-Ṣaaliḥ/TRANSLITERATION.md` (the source of truth)
2. Run the sync from the Maktabat-Abee-Ṣaaliḥ project:
   ```
   node -e "/* copy TRANSLITERATION.md + tools/scheme-data.js + tools/check-transliteration.js to every project with html files */"
   ```
3. Verify each project's copy matches: `diff TRANSLITERATION.md <project>/TRANSLITERATION.md`

## 6. Glossary

- **Muḍaaf**: a construct noun ("X of the Y") — the article after it drops Alif and
  becomes `ul-` (or `il-` after Kasrah).
- **Iḍaafah**: the construct state itself.
- **Waṣl**: the joining of words; the article loses its Alif in speech.
- **Waqf**: pausing at the end of a word or phrase.
- **Taa ul-Marbootah** (ة): the "tied Taa" — keeps `-t` in Waṣl, `-ah` in pause.
- **Ḥuroof ush-Shamseeyah**: the 14 sun letters that assimilate the article's Laam.
- **Ḥuroof uqmoon**: the 14 moon letters that keep the article's Laam.

---

*This file is versioned in every Freebuff Projects workspace. It must not be modified except
by a human with knowledge of the scheme or by an agent acting on their explicit
instruction.*
