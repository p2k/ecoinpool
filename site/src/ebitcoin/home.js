
/*
 * Copyright (C) 2011  Patrick "p2k" Schneider <patrick.p2k.schneider@gmail.com>
 *
 * This file is part of ebitcoin.
 *
 * ebitcoin is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * ebitcoin is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with ebitcoin.  If not, see <http://www.gnu.org/licenses/>.
 */

userCtx.ready(function () {
    
    sidebar.selectMainNavItem("home");
    
    var activeClients;
    var pageTabs;
    
    function loadClients () {
        ebitcoinDb.view("doctypes/doctypes", {
            key: "client",
            include_docs: true,
            success: function (resp) {
                var active = [], inactive = [];
                $.each(resp.rows, function () {
                    var isActive = ($.inArray(this.id, activeClients) != -1);
                    var entry = {
                        id: this.id,
                        name: this.doc.name,
                        chain: poolTypeInfo.get(this.doc.chain).title
                    };
                    if (isActive)
                        active.push(entry);
                    else
                        inactive.push(entry);
                });
                
                var tabs = [
                    {id: "active_clients", title: "Active Clients", elt: $(templates.clientsTable({id: "active_clients_table", clients: active}))}
                ];
                
                $("#content").empty();
                
                if (userCtx.isAdmin()) {
                    makeToolbar([{type: "add", title: "New Client", href: "client/"}]);
                    tabs.push({id: "inactive_clients", title: "Inactive Clients", elt: $(templates.clientsTable({id: "inactive_clients_table", clients: inactive}))});
                }
                else {
                    makeToolbar();
                }
                
                pageTabs = new TabHandler(tabs);
            }
        });
    };
    
    // Start by loading the main configuration
    ebitcoinDb.openDoc("configuration", {
        success: function (conf) {
            activeClients = conf.active_clients;
            loadClients();
        },
        error: function () {
            $("#content").empty();
            var fixthis = "";
            if (userCtx.isAdmin())
                fixthis = ' <a href="client/">Fix this</a>.';
            makeToolbar("This server has been freshly installed and is not configured yet." + fixthis);
        }
    });
});
