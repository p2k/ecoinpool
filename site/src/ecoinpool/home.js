
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
    
    function loadSubpools () {
        ecoinpoolDb.view("doctypes/doctypes", {
            key: "sub-pool",
            include_docs: true,
            success: function (resp) {
                if (activeSubpools === undefined) {
                    if (resp.rows.length == 0 || !userCtx.isAdmin()) {
                        $("#content").empty();
                        var fixthis = "";
                        if (userCtx.isAdmin())
                            fixthis = ' <a href="subpool/">Fix this</a>.';
                        makeToolbar("This server has been freshly installed and is not configured yet." + fixthis);
                        return;
                    }
                    else
                        activeSubpools = [];
                }
                
                var active = [], inactive = [];
                $.each(resp.rows, function () {
                    var aux = (this.doc.aux_pool !== undefined ? " + " + poolTypeInfo.get(this.doc.aux_pool.pool_type).title : "");
                    var isActive = ($.inArray(this.id, activeSubpools) != -1);
                    var entry = {
                        id: this.id,
                        name: this.doc.name,
                        title: this.doc.title,
                        type: poolTypeInfo.get(this.doc.pool_type).title + aux,
                        url: "http://" + location.hostname + ":" + this.doc.port + "/",
                        round: (this.doc.round === undefined ? "-" : this.doc.round)
                    };
                    if (isActive)
                        active.push(entry);
                    else
                        inactive.push(entry);
                });
                
                var tabs = [
                    {id: "active_subpools", title: "Active Subpools", elt: $(templates.subpoolsTable({id: "active_subpools_table", subpools: active}))}
                ];
                
                $("#content").empty();
                
                if (userCtx.isAdmin()) {
                    makeToolbar([{type: "add", title: "New Subpool", href: "subpool/"}]);
                    tabs.push({id: "inactive_subpools", title: "Inactive Subpools", elt: $(templates.subpoolsTable({id: "inactive_subpools_table", subpools: inactive}))});
                }
                else {
                    makeToolbar();
                }
                
                pageTabs = new TabHandler(tabs);
            }
        });
    };
    
    // Start by loading the main configuration
    ecoinpoolDb.openDoc("configuration", {
        success: function (conf) {
            activeSubpools = conf.active_subpools;
            loadSubpools();
        },
        error: loadSubpools
    });
});
