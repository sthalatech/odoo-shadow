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
