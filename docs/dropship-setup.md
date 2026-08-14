# Dropship Feature Setup (feat/darkstore)

## Objective
Enable Odoo's out-of-the-box dropship feature for the Darkstore use case.

## Changes Made on Workspace (isha-life)

### 1. Module Installation
- Installed `stock_dropshipping` (Odoo community addon)
- Created `dropship_field_shim` custom addon to re-add fields missing from
  uninstalled custom modules (isha_api_integration, isha_auto_invoice, etc.)

### 2. Companies
- **Created "Dropship Delhi"** (company ID 8) with INR currency
- **Company 4 (Prime Ridge Corp.)** already had dropship picking type (525) and rule (279)

### 3. Dropship Route
- Route ID 118 ("Dropship") — sale_selectable=true, product_selectable=true
- Rules exist for companies 1-5 (auto-created by stock_dropshipping)
- Dropship picking types (code='dropship') exist for companies 1-5

### 4. Test Data
- Vendor: "Dropship Test Vendor" (partner 136471)
- Customer: "Dropship Test Customer" (partner 136472)
- Product: "Dropship Test Product" (product 31887, code DS-TEST-001)
  - Route: Dropship (118)
  - Seller: Dropship Test Vendor, min_qty=1, price=300

### 5. Dropship Workflow Test Results

| Step | Action | Result |
|------|--------|--------|
| 1 | Create SO in company 4 with route_id=118 on SOL | SO *08600, state=draft |
| 2 | Confirm SO | state=sale, procurement group created |
| 3 | Auto-created PO | PO *00389, vendor=Dropship Test Vendor, company=4 |
| 4 | Confirm PO | state=purchase, dropship picking DS/00002 created |
| 5 | Validate picking | state=done, supplier→customer delivery |
| 6 | qty_delivered synced | SOL qty_delivered=5.0 |
| 7 | Create invoice | Draft invoice, amount=₹2,611.60, company=4 |

### 6. Odoo Dropship Workflow (Default)
1. Product has Dropship route (on product or sale order line)
2. Sale order confirmed → procurement finds Dropship route
3. Purchase order (RFQ) auto-created to vendor
4. PO confirmed → dropship picking created (supplier→customer, no warehouse)
5. Picking validated → delivery complete, qty_delivered synced to SOL
6. Invoice created from SO based on delivered quantity

### 7. Data Fixes Applied
- Deleted corrupted `ir_default` entries (masked by masker)
- Fixed `loyalty_rule.product_domain` (masked to `**`, set to `[]`)
- Set `product_supplierinfo.company_id = NULL` (was company 1, SO in company 4)
- Reset admin password to 'admin' via Odoo shell
- Uninstalled `isha_api_integration` (code missing, orphaned ir_model_inherit)
- Deleted orphaned `ir_model_inherit`, `ir_model_data`, `ir_model` for singer.integration
