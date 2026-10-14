# Drive Fresh — store build

Shopify store `drivefresher.myshopify.com`, converting Drive Fresh from car accessories to unbranded golf equipment. The store keeps the
Drive Fresh name and logo.
The original build checklist is in [`docs/HANDOFF.md`](docs/HANDOFF.md).

| Path | What it is |
|---|---|
| `theme/` | Changed and new files on top of **Dawn 15.5.0** (the live theme). Not a full theme — only what differs. |
| `products/drive-fresh-products.csv` | The three catalog products, as **drafts**, in Shopify's product-import format. |
| `docs/policies/` | Paste-ready HTML for **Settings → Policies** (refund + shipping), copied from the live pages. |

## Status (2026-10-14)

### Theme — staged, not live
All of `theme/` has been uploaded to an **unpublished** copy of the live theme named **"Drive Fresh (staging)"**
(`gid://shopify/OnlineStoreTheme/167627948249`). The live Dawn theme was not touched.

To review: **Online Store → Themes → Drive Fresh (staging) → Preview / Customize**. Publish it from there when happy.

Six pre-rename files (`sections/ge-*.liquid`, `snippets/ge-final-sale-notice.liquid`, `assets/golf-empire.css`)
still exist in the staging theme because the API connection can't delete theme files. They've been overwritten
with empty stubs labelled "Unused (delete me)" and have no presets, so they don't appear in the theme editor.
Deleting them in Edit code is optional tidying.

What changed:

- **Homepage** (`templates/index.json`): announcement bar → header → hero → 4-stat trust strip → category grid
  (the 5 smart collections, 3:4 tiles) → featured clubs → brand-story band → 3-step delivery timeline → footer.
  The car-interior video hero, "Upgrade Your Ride" copy, and the **"30-Day Returns"** trust badge are gone.
- **Look** (`config/settings_data.json`): pine `#102A1C` / bone `#EDE8DC` / brass `#C2A05C`; Bodoni Moda headings,
  Inter body. The existing Drive Fresh logo and favicon are kept.
  Brass text on light backgrounds uses a darker brass (`#6B5222`) — real brass on bone is 2:1 contrast and unreadable.
- **Final-sale disclosure next to Add to cart** (`snippets/df-final-sale-notice.liquid`, rendered from
  `snippets/buy-buttons.liquid`) on every product page.
- **Cart-page acknowledgment** (`sections/main-cart-footer.liquid`): the disclosure plus a required checkbox with the
  exact handoff wording. Checkout won't submit until it's ticked; Shop Pay/PayPal express buttons are locked until
  then. The tick is saved as the cart attribute **"Final sale acknowledged: Yes"**, which shows on the order under
  *Additional details* — that's your chargeback evidence.
- **Nothing bypasses the cart page:** cart type set to *Page* (no popup with its own checkout button) and the
  product page's "Buy it now" button turned off. **Keep both that way**, or customers can check out without the
  acknowledgment.
- Footer: Help menu + "Not affiliated with any golf equipment manufacturer." Country/language pickers removed (US only).

Before publishing, check in the theme editor:
1. **Theme settings → Typography** shows Bodoni Moda / Inter. (I couldn't render the storefront from my environment
   to confirm the font handles.)
2. The header and announcement bar use the dark pine scheme, so the Drive Fresh logo (made for the old dark
   header) stays legible. Glance at it in the preview anyway.
3. Hero image: DF Hero section → Image. Until then it shows a pine "DF" monogram panel, not a fake photo.
4. Collection tiles use each collection's own image — set those under Products → Collections (900×1200).
5. Main menu still reads Home / Catalog / About Us — add the five collections in **Online Store → Navigation**.

Limits of the acknowledgment: someone who goes straight to `/checkout` skips the cart page. A real checkout
checkbox needs Shopify Plus or a terms-checkbox app; this is the free version the handoff describes.

### Catalog — created in the store as DRAFT
All three products from `products/drive-fresh-products.csv` were created on 2026-10-14 through the Admin API, status
**Draft** (not buyable, not on any sales channel). Vendor *Drive Fresh*, the tags the smart collections match on, the
required opening disclosure and closing "Not affiliated…" line, all 9 SKUs, no compare-at prices, inventory not
tracked. Each one shows up in its smart collection (irons → `golf-irons`, driver → `drivers-woods`, wedges →
`putters-wedges`) while still a draft. The CSV remains the source of truth if they ever need re-importing.

The descriptions contain **only** what the handoff states (piece count, lofts, flex options). Head material,
shaft weight, bounce, hosel adjustability range, swing weights, handedness etc. are **deliberately missing** — add
them from the supplier's spec sheet before setting a product to Active. Weights are blank, so set them too if your
shipping rates are weight-based.

### Settings → Policies — must fix by hand (API scope missing)
The legal policies the footer links to still contradict the pages:

| Policy | Problem |
|---|---|
| Refund policy | **"We accept returns within 30 days"** — directly contradicts final sale |
| Shipping policy | "1–3 weeks from the day your order ships", $8 / $15 rates |

Fix: Settings → Policies → Refund policy → `<>` (HTML view) → replace with `docs/policies/refund-policy.html`.
Same for Shipping policy with `docs/policies/shipping-policy.html`.

### Copy
The About Us sentence claiming the clubs "come out of the same factories and the same processes" as the major
brands was removed on 2026-10-14. It was unprovable. Don't claim anything about where the clubs are made.

## Working on the theme

With [Shopify CLI](https://shopify.dev/docs/storefronts/themes/tools/cli):

```sh
# pull the full staging theme to work locally
shopify theme pull --store drivefresher --theme 167627948249 --path ./theme-full
# push only this repo's files on top of a theme, leaving everything else alone
shopify theme push --store drivefresher --theme 167627948249 --path ./theme --nodelete
```

Never push to the live theme directly. Make changes on the staging theme and publish it from the admin.

House rules for anything added to the theme:
- No brand names, logos or photography — not in copy, alt text, tags or images.
- Nothing may contradict the final-sale policy and its carve-outs (damaged / defective / not-as-described /
  never-delivered, and cancellation if the stated window is missed).
- Trust-strip stats must be literally true. No invented customer counts or ratings.
- No strikethrough compare-at prices unless the item genuinely sold at that price.
