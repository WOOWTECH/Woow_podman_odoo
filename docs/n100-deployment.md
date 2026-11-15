# Deployment reliability

After successful initialization of an empty tenant database, the bootstrap helper now sets ODOO_TENANT_FRESH. The installer can then use the fresh-adoption gate rather than treating a database without any previous release state as an upgrade. Existing initialized tenants never rerun base initialization or reset the administrator.

[Existing N100 deployment and functional evidence](https://github.com/WOOWTECH/Woow_ubuntu_version_control/blob/195dcda9357100a7821407e1c8469a349acc9831/distribution/docs/reboot-acceptance.md). Source fixes do not themselves restart an existing installation.
