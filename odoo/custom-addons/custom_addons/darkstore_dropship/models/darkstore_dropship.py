# -*- coding: utf-8 -*-
from odoo import models, fields, api


class SaleOrderLine(models.Model):
    _inherit = 'sale.order.line'

    fulfillment_wh_name = fields.Char(
        string='Fulfillment WH',
        help='Name of the fulfillment partner (dropship vendor) for this line. '
             'When set, the auto-generated dropship PO will use this partner '
             'as the vendor instead of the product\'s supplier info.',
    )

    def _prepare_procurement_values(self, group_id=False):
        """Pass the fulfillment partner down to the procurement so that
        _run_buy can use it as the PO vendor."""
        values = super()._prepare_procurement_values(group_id)
        if self.fulfillment_wh_name:
            partner = self.env['res.partner'].search(
                [('name', '=ilike', self.fulfillment_wh_name)],
                limit=1,
            )
            if partner:
                values['fulfillment_partner_id'] = partner.id
        return values


class StockRule(models.Model):
    _inherit = 'stock.rule'

    @api.model
    def _run_buy(self, procurements):
        """Inject a virtual supplierinfo whose partner_id is the fulfillment
        WH from the sale order line.  _run_buy checks supplierinfo_id first,
        so if we set it the rest of the method uses our custom vendor for the
        PO partner_id, the PO grouping domain, and the picking partner."""
        for procurement, rule in procurements:
            fulfillment_partner_id = procurement.values.get('fulfillment_partner_id')
            if fulfillment_partner_id and not procurement.values.get('supplierinfo_id'):
                # Use the product's first real supplier info for price / delay /
                # currency, but override the partner.
                real_supplier = procurement.product_id._prepare_sellers(False)[:1]
                virtual = self.env['product.supplierinfo'].new({
                    'partner_id': fulfillment_partner_id,
                    'delay': real_supplier.delay if real_supplier else 0,
                    'currency_id': (
                        real_supplier.currency_id.id if real_supplier
                        else procurement.company_id.currency_id.id
                    ),
                    'price': real_supplier.price if real_supplier else 0.0,
                    'product_id': procurement.product_id.product_tmpl_id.id,
                    'company_id': procurement.company_id.id,
                })
                procurement.values['supplierinfo_id'] = virtual
        return super()._run_buy(procurements)


class PurchaseOrder(models.Model):
    _inherit = 'purchase.order'

    def _prepare_sale_order_data(self, name, partner, company, direct_delivery_address):
        """Fix the delivery address and fiscal position of the inter-company
        SO created from a dropship PO.

        1. Delivery address: Odoo's enterprise
        `sale_purchase_inter_company_rules` computes
        `direct_delivery_address = picking_type_id.warehouse_id.partner_id
        or dest_address_id`.  For a dropship PO the picking type is the
        dropship type, whose warehouse partner is the *fulfillment vendor*
        (the dispatch address shown on reports) - not where the goods are
        delivered.  The goods go straight from the vendor to the end
        customer, i.e. the PO's `dest_address_id`.  Out of the box the
        dropship picking type has no warehouse, so the `or` falls through
        to `dest_address_id`; once the picking type is linked to the
        vendor warehouse (for the dispatch address on the PDF), the wrong
        value wins.  Force the end-customer address here so the IC SO, its
        delivery picking and its invoice all carry the customer's address.

        2. Fiscal position: the enterprise module computes it in the PO's
        company context (`_get_fiscal_position(partner)` on a PO record of
        the source company), so the IC SO either gets no fiscal position or
        one belonging to the wrong company (dropped by the company check on
        create).  Recompute it in the IC company's context so the IC SO is
        taxed per the destination company's rules (e.g. intra-state taxes
        mapped to IGST for inter-state supplies).
        """
        if self.picking_type_id.code == 'dropship' and self.dest_address_id:
            direct_delivery_address = self.dest_address_id.id
        res = super()._prepare_sale_order_data(
            name, partner, company, direct_delivery_address)
        fpos = self.env['account.fiscal.position'].with_company(
            company)._get_fiscal_position(partner)
        if fpos:
            res['fiscal_position_id'] = fpos.id
        return res
