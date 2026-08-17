# Darkstore Dropship

Custom module for inter-company darkstore dropship workflow built on Odoo's
`stock_dropshipping`.

## Development

This module is developed incrementally on the `feat/darkstore` branch.
Each feature is added as a separate commit.

## Dependencies

- `sale`, `purchase`, `stock`, `account`
- `sale_stock`, `stock_dropshipping`

## What it does

- **Fulfillment vendor on the SOL** (`fulfillment_wh_name`): the dropship PO
  is raised to this partner instead of the product's default supplierinfo.
- **IC SO delivery address**: when the enterprise `sale_purchase_inter_company_rules`
  creates the inter-company SO from a dropship PO, the shipping address is
  forced to the PO's `dest_address_id` (the end customer). The dropship
  picking type's warehouse partner is only the *dispatch* address (used on
  reports); it must never become the delivery address on the IC SO, its
  delivery picking, or its invoice.
- **IC SO fiscal position**: the enterprise module computes the fiscal
  position in the *source* company's context, so the IC SO would get no
  (or a wrong-company) fiscal position and be over/under-taxed. It is
  recomputed in the destination company's context (e.g. intra-state
  CGST/SGST mapped to IGST for inter-state supplies).

## Installation

Install via Odoo Apps or:

```
odoo-bin -d <db> -i darkstore_dropship
```
