# -*- coding: utf-8 -*-
{
    'name': 'Darkstore Dropship',
    'version': '17.0.0.0.1',
    'category': 'sales/sales',
    'summary': 'Darkstore dropship workflow: inter-company SO → PO → direct delivery',
    'description': """
Darkstore Dropship
==================
Extends Odoo's out-of-the-box dropship (stock_dropshipping) with
inter-company workflow customizations:

- Per-company dropship route and rule configuration
- Vendor selection driven by product supplier info (shared across companies)
- Smart-button visibility for dropship pickings on SO/PO forms
- Auto-invoice on dropship picking validation (optional, per picking type)

This module is built incrementally; features are added step by step.
""",
    'license': 'LGPL-3',
    'depends': [
        'sale',
        'purchase',
        'stock',
        'account',
        'sale_stock',
        'stock_dropshipping',
    ],
    'data': [
        'views/sale_order_views.xml',
    ],
    'installable': True,
    'auto_install': False,
    'application': True,
}
