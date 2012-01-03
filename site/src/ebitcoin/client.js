
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
    
    var mainConfig;
    
    function chainSelectorChange () {
        var chain = $("#chain select").val();
        $("#port input").attr("placeholder", poolTypeInfo.get(chain).p2p);
    };
    
    function renderClientConfig () {
        var config = [
            {id: "chain", name: "Chain:", field: {type: "select", options: poolTypeInfo.getAsOptions(poolTypeInfo.allEbitcoinTypes), value: doc.chain}},
            {id: "name", name: "Name:", field: {type: "text", value: doc.name}},
            {id: "host", name: "Target Host:", field: {type: "text", value: doc.host, placeholder: "localhost"}},
            {id: "port", name: "Target Port:", field: {type: "text", value: doc.port}}
        ];
        
        var rev, toolbuttons = [{title: "Save Configuration", type: "save", click: saveClientConfig}];
        if (doc._rev === undefined)
            rev = "0";
        else {
            rev = doc._rev.substr(0, doc._rev.indexOf("-"));
            if (mainConfig.active_clients && $.inArray(doc._id, mainConfig.active_clients) != -1)
                toolbuttons.push({title: "Deactivate Client", type: "unload", click: toggleClientActivation});
            else
                toolbuttons.push({title: "Activate Client", type: "load", click: toggleClientActivation});
        }
        
        return {
            tab: {id: "configuration", title: "Configuration", elt: $(templates.configTable({config: config, id: doc._id, rev: rev}))},
            toolbuttons: toolbuttons,
            init: function () {
                installFieldsLogic("#client_config .content td", {
                    chain: {select_change: chainSelectorChange},
                    port: {text_input_keydown: filterIntegerOnly}
                });
                
                chainSelectorChange();
            }
        };
    };
    
    function displayClient () {
        $("#content").empty();
        
        var toolbuttons = [];
        var tabs = [];
        var inits = [];
        
        /*if (doc._rev !== undefined) {
            
        }*/
        
        if (userCtx.isAdmin()) {
            var cfg = renderClientConfig();
            $.merge(toolbuttons, cfg.toolbuttons);
            tabs.push(cfg.tab);
            inits.push(cfg.init);
        }
        else {
            toolbuttons = "(Block Explorer frontend not implemented yet)";
        }
        
        // Install the toolbar
        makeToolbar(toolbuttons);
        // Install all tabs
        pageTabs = new TabHandler(tabs);
        
        // Run init functions
        $.each(inits, function () {this();});
    };
    
    function saveClientConfig () {
        // Write back all fields and validate
        doc.chain = getFieldValue("#chain");
        doc.name = getFieldValue("#name");
        if (doc.name === undefined) {
            $("#name input").focus();
            alert("Please enter a name!");
            return;
        }
        doc.host = getFieldValue("#host");
        doc.port = getFieldValue("#port", true);
        if (doc.port !== undefined && (doc.port <= 0 || doc.port >= 65536)) {
            $("#port input").focus();
            alert("Please enter a valid port!");
            return;
        }
        
        // Submit
        ebitcoinDb.saveDoc(doc, {
            success: function (resp) {
                var path = location.href.split("/");
                var last = path[path.length-1];
                if (last == "client")
                    location.href = location.href + "/" + resp.id;
                else if (last != resp.id)
                    location.href = path.slice(0, path.length-1).join("/") + "/" + resp.id;
                else
                    location.reload();
            },
            error: function (status, error, reason) {
                alert("Your changes could not be saved: " + reason);
            }
        });
    };
    
    function toggleClientActivation () {
        var button = $(this);
        if (button.hasClass("load")) {
            if (mainConfig.active_clients === undefined)
                mainConfig.active_clients = [doc._id];
            else if ($.inArray(doc._id, mainConfig.active_clients) == -1)
                mainConfig.active_clients.push(doc._id);
        }
        else if (mainConfig.active_clients !== undefined) {
            var pos = $.inArray(doc._id, mainConfig.active_clients);
            if (pos != -1)
                mainConfig.active_clients.splice(pos, 1);
        }
        
        ebitcoinDb.saveDoc(mainConfig, {
            success: function (resp) {
                location.reload();
            },
            error: function (status, error, reason) {
                alert("The Client could not be toggled: " + reason);
            }
        });
    };
    
    // Add and select my navigation item
    sidebar.addMainNavItem(siteURL + "_show/client/" + (doc._rev === undefined ? '' : doc._id), (doc._rev === undefined ? "New Client" : doc.name), true);
    
    // Start by loading the main configuration
    ebitcoinDb.openDoc("configuration", {
        success: function (conf) {
            mainConfig = conf;
            displayClient();
        },
        error: function () {
            mainConfig = {_id: "configuration", type: "configuration"};
            displayClient();
        }
    });
    
});
