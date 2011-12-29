
/*
 * Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
 *
 * This file is part of ecoinpool.
 *
 * ecoinpool is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * ecoinpool is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with ecoinpool.  If not, see <http://www.gnu.org/licenses/>.
 */

userCtx.ready(function () {
    
    sidebar.selectMainNavItem("home");
    
    var activeSubpools;
    var pageTabs;
    
    function poolType (type) {
        switch (type) {
            case "sc": return "SolidCoin";
            case "btc": return "BitCoin";
            case "nmc": return "NameCoin";
            case "ltc": return "LiteCoin";
            default: return type;
        }
    };
    
    function loadSubpools () {
        confDb.view("doctypes/doctypes", {
            key: "sub-pool",
            include_docs: true,
            success: function (resp) {
                var active = [], inactive = [];
                $.each(resp.rows, function () {
                    var aux = (this.doc.aux_pool !== undefined ? " + " + poolType(this.doc.aux_pool.pool_type) : "");
                    var isActive = ($.inArray(this.id, activeSubpools) != -1);
                    var entry = {
                        id: this.id,
                        name: this.doc.name,
                        type: poolType(this.doc.pool_type) + aux,
                        port: this.doc.port,
                        round: (this.doc.round === undefined ? "-" : this.doc.round)
                    };
                    if (isActive)
                        active.push(entry);
                    else
                        inactive.push(entry);
                });
                
                var tabs = [
                    {id: "active_subpools", title: "Active Subpools", elt: $(templates.subpoolsTable({subpools: active}))}
                ];
                
                $("#content").empty();
                
                if (userCtx.isAdmin()) {
                    makeToolbar([{type: "add", title: "New Subpool", href: "subpool/"}]);
                    tabs.push({id: "inactive_subpools", title: "Inactive Subpools", elt: $(templates.subpoolsTable({subpools: inactive}))});
                }
                else {
                    makeToolbar();
                }
                
                pageTabs = new TabHandler(tabs);
            }
        });
    };
    
    // Start by loading the main configuration
    confDb.openDoc("configuration", {
        success: function (conf) {
            activeSubpools = conf.active_subpools;
            loadSubpools();
        },
        error: function () {
            makeToolbar("This pool has been freshly installed and is not configured yet.");
        }
    });
});
