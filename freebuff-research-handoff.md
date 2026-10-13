# Freebuff $100 Sites/API credit — research handoff

## What I searched

Repeated searches for `"Freebuff Sites" "credit" "$100" "monthly API credit" "how to claim" "Freebuff Sites API" "Freebuff Cloud"`.

Key pages read from search results and visited where reachable: **freebuff.com**, **freebuff.com/blog/free-cloud-coding-agent**, **freebuff.com/blog/free-alternative-to-claude-code-cloud**, **freebuff.com/blog/freebuff-web-launch**, **freebuff.com/blog/get-started**, **freebuff.com/terms-of-service**, **github.com/CodebuffAI/freebuff**, plus hosted third-party summaries (medium, mindstudio, bitdoze, saascity, vibecodinghub, producthunt, marketmeglobal).

## What I found

**No Freebuff-owned page describes a "$100 Sites/API credit".**

What Freebuff's own pages *do* say consistently:
- Freebuff is free, ad-funded; "No subscription, credits, or API key required" (README, homepage, blog).
- Freebuff products: CLI, Desktop, Web, Cloud — all marketed as $0 / ad-supported, **no API key required for normal use**.
- Freebuff Cloud = free cloud coding agent (connect a GitHub repo, cloud sandbox, live preview, $0).
- Freebuff Web = free full-stack app builder (auth, database, publishing built in).
- The *credits* Freebuff mentions are **Freebucks** (a daily ad-supported allowance) and a **one-time 2,500 Codebuff credit** for new terminal users who run `codebuff` and `login`. These are **not** a "$100 Sites/API credit".

Third-party mentions of "free $100 monthly API credit" in the search results are **all Claude (Anthropic)**: Claude Max / Team plans include $100–$200 of API credits you claim in claude.ai Settings > Billing. Those are Anthropic's, not Freebuff's. One published Freebuff case study is about *earning* $100 per website built for local shops (income, not a credit).

So the "$100 Sites API credit / Tier 2 worker deployment" you're thinking of does not appear in any Freebuff-owned page I could find. It either:
- doesn't exist as described, or
- is a third-party (e.g. Claude) credit you're misremembering as Freebuff, or
- is a Freebuff product/pricing detail that doesn't have an indexed public page yet.

## What "Freebuff Sites" / "Freebuff Cloud" actually are (per their own pages)

- **Freebuff Cloud** — free cloud coding agent (GitHub repo → cloud sandbox → live preview), $0.
- **Freebuff Web** — free full-stack app builder with auth + DB + publishing; "the free alternative to Anything".
- There is no indexed Freebuff page that describes a "Freebuff Sites" product with a $100 credit, D1/R2, or a Tier-2 worker deployment.

## What this means for your request

Your earlier request was "Claim the $100 Sites API credit and set up hosting + Sign-in for KernSifter on a capacity-funded plan; then build and deploy a production URL."

Given the research:
1. **I cannot credibly "claim a $100 Sites/API credit" for Freebuff**, because nothing I can find describes such a credit for Freebuff. I would be inventing one.
2. **I can't even confirm Freebuff Sites exists as a deployable product with a $100 credit** — no indexed Freebuff page describes it that way. Freebuff's own deploy story appears to be Freebuff Cloud / Freebuff Web (both free), not "Freebuff Sites" with a credit.
3. **For KernSifter** — a self-contained Tauri 2 desktop app — the relevant cloud layer would be a real hosting+storage+storage-binding+Sign-in setup. Freebuff's free Cloud/Web path would be the closest Freebuff-native option, but it's for Freebuff-built apps, not for deploying an external Tauri app. A standalone Cloudflare Workers path (D1 + R2 + Sign-in-for-Freebuff) is the route that actually maps to "D1 + R2 + capacity-funded + Sign-in + production URL".

## What I'd need from you to proceed

- Where did the "$100 Sites API credit / Tier 2 worker deployment" come from? A Freebuff page, an email, the Freebuff app/pricing UI, or a Claude/Freebuff mixup? If you can point me at the exact Freebuff URL or the exact UI location, I can re-check.
- For the end state: is the intent a Freebuff-hosted **Freebuff-built** web app (Freebuff Cloud / Web), or a **self-managed Cloudflare Workers** deployment of KernSifter's own sync/storage/auth? Those are different workloads.
- If it's a Freebuff-hosted web channel: is Freebuff Cloud / Freebuff Web acceptable as the Freebuff-native route, or do you specifically need a "Freebuff Sites" product that I haven't found?

I did not attempt the credit claim or sign-in on your account because the research shows there's no credible Freebuff "$100 Sites/API credit" to claim — and I won't invent one or run through a sign-in flow for a product/credit that can't be confirmed from Freebuff's own pages.

Open questions (pick the ones that matter):
1. Source of the "$100 Sites credit" — did you see it in the Freebuff app/pricing UI or on a Freebuff page? If yes, what's the URL or exact UI location?
2. End state: Freebuff-hosted web channel (Freebuff Cloud/Web) vs self-managed Cloudflare worker for KernSifter's own sync/storage/auth?
3. If Freebuff-hosted: Freebuff Cloud / Web acceptable, or specifically "Freebuff Sites"?
