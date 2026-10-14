# Golf Empire — Store Build Handoff

> Original handoff as of 2026-10-14. For what has since been done, see the **Status** section of the root `README.md`.

**Store:** Golf Empire — `drivefresher.myshopify.com`
**Plan:** Shopify Basic ($20/mo) · USD · United States · timezone EDT
**Niche:** Unbranded / generic premium golf equipment, dropshipped from AliExpress suppliers
**Status as of 2026-10-14:** Converted from a car-accessories store ("Drive Fresh"). Content pages and collections are done. Catalog is empty. Theme is still the old car-accessory design.

---

## Read this first

This store sells dropshipped golf clubs at $300–$650. Two things govern every decision below:

1. **Nothing may carry a real brand's name, logo, or photography.** No TaylorMade, Ping, Callaway, Titleist, Scotty Cameron, Mizuno, Cobra, Srixon. Not in titles, descriptions, tags, alt text, metafields, or images. The supplier's own listings use these marks — strip them. Trademark counterfeiting is criminal, and brand enforcement firms place test orders on stores exactly like this one.
2. **The policy is final sale, with four mandatory carve-outs** (damaged / defective / not-as-described / never-delivered, plus cancellation if the stated ship window is missed). This is already written into the pages. Do not let any new copy contradict it.

---

## ✅ Already done — do not redo

### Content pages (live, golf-specific)
| Page | Handle | State |
|---|---|---|
| About Us | `/pages/about-us` | Rewritten — "paying for a logo, not a golf club" positioning |
| Shipping Policy | `/pages/shipping-policy` | 2–4 week honest timeline, customs, tracking, insurance |
| Return Policy | `/pages/return-policy` | Final sale + 4 carve-outs + EU/UK statutory clause |
| FAQ | `/pages/faq` | Shipping, returns, club specs, flex guidance |
| Contact Us | `/pages/contact-us` | Email `solodrivenate@gmail.com`, 24hr response |

### Smart collections (5, auto-fill by product tag)
| Collection | Handle | Tag rule |
|---|---|---|
| Forged Irons & Iron Sets | `golf-irons` | tag = `irons` |
| Titanium & Carbon-Fiber Drivers | `drivers-woods` | tag = `drivers` |
| Fairway Woods & Hybrids | `fairway-woods-hybrids` | tag = `fairway-woods` OR `hybrids` |
| Precision Wedges & Putters | `putters-wedges` | tag = `putters` OR `wedges` |
| Tour Golf Bags & Accessories | `bags-accessories` | tag = `bags` OR `accessories` |

Tags are lowercase-hyphenated. Any new product must use these exact tags or it won't appear anywhere.

### Shipping zones
Already United States only. Verified 2026-10-14. No action needed.

---

## 🔴 Blocking — store cannot launch without these

### 1. Product photography
**Nobody can do this but the store owner.** Every product and collection needs images, and they must be unbranded.

Options, best first:
- Order one sample of each product, photograph it yourself (also gives unique images for SEO, and verifies the supplier isn't shipping counterfeits — see #2)
- Ask the supplier for unbranded or white-label photo sets
- Do **not** pull images from brand sites, competitor stores, or the supplier's branded listings

Sizes needed:
- Hero: 4:5 portrait, 1400×1750
- Collection tiles: 3:4 portrait, 900×1200 (×5)
- Product: 1:1 square, 1200×1200, 4–5 angles each

Shopify's API cannot upload from a local path — images must be uploaded through admin, or hosted at a public HTTPS URL first.

### 2. Supplier verification
Order one sample of each SKU before listing anything. On arrival inspect clubhead, shaft band, grip, and headcover for brand marks. If any brand mark is present, that product cannot be sold. This is the single decision that determines whether the business is legal.

### 3. Recreate the catalog
The store has **zero products**. Three drafts were created and then deleted. Rebuild them with the final-sale disclosure included.

**Product 1 — Forged Cavity-Back Iron Set (4-PW, 7 Pieces)**
- Price $649.00 · Option: Flex → Regular, Stiff
- SKUs `IRON-FCB-7-R`, `IRON-FCB-7-S`
- Type: Golf Irons · Vendor: Golf Empire · Tags: `irons`, `iron-set`, `forged`, `cavity-back`
- Status: DRAFT until photos exist

**Product 2 — Adjustable Carbon-Composite Driver**
- Price $499.00 · Options: Loft → 9.0°, 10.5° · Flex → Regular, Stiff, Extra Stiff (6 variants)
- SKUs `DRV-CC-{90|105}-{R|S|XS}`
- Type: Golf Drivers · Tags: `drivers`, `carbon-composite`, `adjustable`

**Product 3 — Milled Face Precision Wedge Set (52°, 56°, 60°)**
- Price $299.00 · single default variant · SKU `WDG-MF-3`
- Type: Golf Wedges · Tags: `wedges`, `milled-face`, `wedge-set`

**Every description must open with:**
```html
<p><strong>All sales final. Damaged, defective, or incorrect items fully covered.</strong><br>
<strong>Estimated delivery: 2–4 weeks.</strong> Ships from our international fulfillment partner.</p>
```
**And close with:** "Not affiliated with any golf equipment manufacturer."

Confirm every technical spec (head material, shaft weight, bounce angles, hosel adjustability range) against the supplier's actual spec sheet before publishing. Do not invent specs — a wrong spec is a "not as described" refund you're obligated to honor.

### 4. Legal policies in Settings → Policies
These are **separate** from the content pages above and are what the storefront footer links to. They may still contain car-accessory text. Generate Shopify's templates, then replace the refund and shipping sections with the text from `/pages/return-policy` and `/pages/shipping-policy` so footer and pages don't contradict each other. A contradiction between them is what a customer wins a chargeback with.

*Note: the Shopify MCP connection lacks the `write_legal_policies` scope, so this must be done manually in admin.*

### 5. Theme rebuild
Still the Drive Fresh car-accessories theme: car interior hero image, "Upgrade Your Ride" headline, Drive Fresh logo, t-shirt placeholder products.

A homepage design spec exists as an HTML preview artifact (deep pine `#102A1C` / bone `#EDE8DC` / brass `#C2A05C`, Bodoni Moda display + Inter body). Sections: announcement bar → sticky header → hero → 4-stat trust strip → category grid → featured products → brand story band → 3-step delivery timeline → footer.

Needs replacing: logo, hero image + headline, featured collection, nav menu, all placeholder content.

**Theme file editing via API is blocked on live/published themes.** Either duplicate the theme first and edit the copy, use Shopify CLI (`shopify theme dev` / `shopify theme pull`) for local development, or do it in the theme customizer.

---

## 🟡 Before taking real orders

### 6. Conspicuous final-sale disclosure
Several states (NY, CA, FL, MA, VA, OH) grant customers a return right by default if a no-return policy isn't *conspicuously* disclosed. The product-description line in #3 covers this. Also add it near the add-to-cart button in the theme.

### 7. Cart-page terms acknowledgment
A required checkbox at **checkout** needs Checkout Extensibility (Shopify Plus) — not available on Basic. Workarounds:
- A terms-checkbox app (~$5–10/mo), or
- Add the disclosure text to the cart page in the theme (free, weaker evidence but far better than nothing)

Text: "I understand delivery takes 2–4 weeks and that all sales are final except for damaged, defective, or incorrect items."

### 8. Remove fake compare-at prices
Do not use strikethrough pricing (e.g. $649 from $1,299) unless the item genuinely sold at that price. FTC deceptive-pricing rules apply.

### 9. Business setup
- NY LLC registration (~$200)
- NYS sales tax registration — nexus exists as a NY resident; then enable tax collection in Shopify
- Separate business bank account for payouts

### 10. Order-notification emails
Confirmation → dispatch w/ tracking → delivery. Silence between order and delivery is the #1 chargeback trigger on a 3-week shipping window.

---

## What Claude Code can and can't help with

**Can:** theme development via Shopify CLI (local Liquid/CSS/JS, pull/push, preview), bulk product CSV generation, image optimization and renaming, scripting against the Admin API if given credentials.

**Can't:** access the Shopify admin UI, upload images it doesn't have, change Settings → Policies or plan-gated checkout features, order supplier samples, or verify whether products are counterfeit.

Realistically the theme rebuild is where Claude Code adds the most value. Policies, settings, and photography are manual.

---

## Biggest risk

Not a lawsuit — the **chargeback rate**. High ticket price + 3-week delivery + final sale is the exact profile that generates disputes. Visa flags merchants above 0.9%; Shopify Payments can withhold payouts before that.

What actually protects the store: tracking on every order, replying to emails within 24 hours, the disclosures above, and refunding generously when something genuinely arrives damaged. Fighting a $650 dispute costs more than refunding it.

---

*This is a build checklist, not legal advice. Before taking real money at this price point, an hour with a New York small-business attorney is worth a few hundred dollars.*
