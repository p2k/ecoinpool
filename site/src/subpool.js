
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

var changes = {};

userCtx.ready(function () {
    
    var inactiveTimout = 120000;
    var speedUpdateTimer;
    
    var workers = [];
    var workerIndexMap = {};
    var workerShareData = {};
    var mainConfig;
    var pageTabs;
    var ebitcoinClients;
    
    var aux_daemon_config;
    
    var thisPoolTypeInfo = poolTypeInfo.get(doc.pool_type);
    
    function daemonText (daemon) {
        if (daemon === undefined)
            return "(all on default)";
        
        var entries = [];
        if (daemon.host)
            entries.push("Host: " + daemon.host);
        if (daemon.port)
            entries.push("Port: " + daemon.port);
        if (daemon.user)
            entries.push("Username: " + daemon.user);
        if (daemon.pass)
            entries.push("Password: " + daemon.pass);
        if (daemon.pay_to)
            entries.push("Pay To: " + daemon.pay_to);
        if (daemon.tag)
            entries.push("Tag: " + daemon.tag);
        if (daemon.ebitcoin_client_id)
            entries.push("ebitcoin Client ID: " + daemon.ebitcoin_client_id);
        
        return entries.join("; ");
    };
    
    function storeDaemonConfig (data) {
        var new_config = {};
        $.each(data, function (key, value) {
            if (value !== undefined && value != "") {
                if (key == "port")
                    new_config[key] = parseInt(value);
                else
                    new_config[key] = value;
            }
        });
        if ($.isEmptyObject(new_config))
            new_config = undefined;
        
        return new_config;
    };
    
    function showCoinDaemonDialog (title, defaultPort, canModifyCoinbase, canUseEbitcoin) {
        $.showDialog(templates.daemonConfigDialog, {
            context: $.extend({
                title: title,
                default_port: defaultPort,
                can_modify_coinbase: canModifyCoinbase,
                can_use_ebitcoin: canUseEbitcoin,
                ebitcoin_clients: ebitcoinClients
            }, doc.coin_daemon),
            load: function (elt) {
                $(elt).find('input[name="port"]').keydown(filterIntegerOnly);
            },
            submit: function (data, callback) {
                var new_config = storeDaemonConfig(data);
                if (new_config.port !== undefined && (new_config.port <= 0 || new_config.port >= 65536))
                    callback({port: "Invalid port."});
                else {
                    $("#coin_daemon span").text(daemonText(new_config));
                    doc.coin_daemon = new_config;
                    callback();
                }
            }
        });
    };
    
    function editCoinDaemonConfig () {
        var pool_type = $("#pool_type select").val();
        var info = poolTypeInfo.get(pool_type);
        if (info.ebc) { // Pool can use ebitcoin -> get clients
            ebitcoinDb.view("clients/by_chain", {
                key: pool_type,
                success: function (resp) {
                    ebitcoinClients = $.map(resp.rows, function (row) {
                        return {title: row.value, value: row.id};
                    });
                    showCoinDaemonDialog(info.title, info.rpc, info.cb, true);
                }
            });
        }
        else {
            showCoinDaemonDialog(info.title, info.rpc, info.cb, false);
        }
    };
    
    function showAuxDaemonDialog (title, defaultPort, canModifyCoinbase, canUseEbitcoin) {
        $.showDialog(templates.daemonConfigDialog, {
            context: $.extend({
                title: title + " Aux",
                default_port: defaultPort,
                can_modify_coinbase: canModifyCoinbase,
                can_use_ebitcoin: canUseEbitcoin,
                ebitcoin_clients: ebitcoinClients
            }, aux_daemon_config),
            load: function (elt) {
                $(elt).find('input[name="port"]').keydown(filterIntegerOnly);
            },
            submit: function (data, callback) {
                var new_config = storeDaemonConfig(data);
                if (new_config.port !== undefined && (new_config.port <= 0 || new_config.port >= 65536))
                    callback({port: "Invalid port."});
                else {
                    $("#aux_daemon span").text(daemonText(new_config));
                    aux_daemon_config = new_config;
                    callback();
                }
            }
        });
    };
    
    function editAuxDaemonConfig () {
        var pool_type = $("#aux_pool_type select").val();
        var info = poolTypeInfo.get(pool_type);
        if (info.ebc) { // Aux pool can use ebitcoin -> get clients
            ebitcoinDb.view("clients/by_chain", {
                key: pool_type,
                success: function (resp) {
                    ebitcoinClients = $.map(resp.rows, function (row) {
                        return {title: row.value, value: row.id};
                    });
                    showAuxDaemonDialog(info.title, info.rpc, info.cb, true);
                }
            });
        }
        else {
            showAuxDaemonDialog(info.title, info.rpc, info.cb, false);
        }
    };
    
    function updateAuxChainSelector () {
        var apts = $("#aux_pool_type select");
        var aux_pools = poolTypeInfo.getAux($("#pool_type select").val());
        if (aux_pools.length > 0) {
            setFieldEnabled("#aux_pool_type", true);
            apts.find("option:first").text("(none)");
            apts.find("option").not(":first").remove();
            $.each(aux_pools, function () {
                apts.append('<option value="' + this.type + '">' + this.title + '</option>')
            });
        }
        else {
            setFieldEnabled("#aux_pool_type", false);
            apts.find("option:first").text("(unsupported)");
            apts.val("");
            apts.find("option").not(":first").remove();
        }
        apts.change();
    };
    
    function auxChainSelectorChange () {
        if ($("#aux_pool_type select").val() == "") {
            setFieldEnabled("#aux_pool_name", false);
            setFieldEnabled("#aux_pool_round", false);
            setFieldEnabled("#aux_daemon", false);
        }
        else {
            setFieldEnabled("#aux_pool_name", true);
            setFieldEnabled("#aux_pool_round", true);
            setFieldEnabled("#aux_daemon", true);
        }
    };
    
    function renderSubpoolConfig () {
        var aux_pool = doc.aux_pool || {};
        aux_daemon_config = aux_pool.aux_daemon;
        var config = [
            {id: "pool_type", name: "Main Chain:", field: {type: "select", options: poolTypeInfo.getAsOptions(poolTypeInfo.allMainTypes), value: doc.pool_type}},
            {id: "name", name: "Name:", field: {type: "text", value: doc.name}},
            {id: "port", name: "Port:", field: {type: "text", value: doc.port}},
            {id: "round", name: "Round:", field: {type: "text", value: doc.round, optional: "Do not count rounds"}},
            {id: "max_cache_size", name: "Max. Cache Size:", field: {type: "text", value: doc.max_cache_size, optional: "Default (300)"}},
            {id: "max_work_age", name: "Max. Work Age:", field: {type: "text", value: doc.max_work_age, optional: "Default (20s)", suffix: "seconds"}},
            {id: "coin_daemon", name: "CoinDaemon Config:", field: {type: "extended", label: "Edit...", value: daemonText(doc.coin_daemon)}},
            
            {id: "aux_pool_type", name: "Aux Pool Chain:", field: {type: "select", options: $.merge([{value: "", title: "(none)"}], poolTypeInfo.getAsOptions(poolTypeInfo.getAux(doc.pool_type))), value: aux_pool.pool_type}},
            {id: "aux_pool_name", name: "Aux Pool Name:", field: {type: "text", value: aux_pool.name}},
            {id: "aux_pool_round", name: "Aux Pool Round:", field: {type: "text", value: aux_pool.round, optional: "Do not count rounds"}},
            {id: "aux_daemon", name: "AuxDaemon Config:", field: {type: "extended", label: "Edit...", value: daemonText(aux_daemon_config)}}
        ];
        
        var rev, toolbuttons = [{title: "Save Configuration", type: "save", click: saveSubpoolConfig}];
        if (doc._rev === undefined)
            rev = "0";
        else {
            rev = doc._rev.substr(0, doc._rev.indexOf("-"));
            if (mainConfig.active_subpools && $.inArray(doc._id, mainConfig.active_subpools) != -1)
                toolbuttons.push({title: "Deactivate Subpool", type: "unload", click: toggleSubpoolActivation});
            else
                toolbuttons.push({title: "Activate Subpool", type: "load", click: toggleSubpoolActivation});
        }
        
        return {
            tab: {id: "configuration", title: "Configuration", elt: $(templates.configTable({config: config, id: doc._id, rev: rev}))},
            toolbuttons: toolbuttons,
            init: function () {
                installFieldsLogic("#pool_config .content td", {
                    coin_daemon: {button_click: editCoinDaemonConfig},
                    port: {text_input_keydown: filterIntegerOnly},
                    round: {text_input_keydown: filterIntegerOnly},
                    max_cache_size: {text_input_keydown: filterIntegerOnly},
                    max_work_age: {text_input_keydown: filterIntegerOnly},
                    pool_type: {select_change: updateAuxChainSelector},
                    aux_pool_type: {select_change: auxChainSelectorChange},
                    aux_pool_round: {text_input_keydown: filterIntegerOnly},
                    aux_daemon: {button_click: editAuxDaemonConfig}
                });
                
                auxChainSelectorChange();
            }
        };
    };
    
    function editWorker () {
        var workerId = $(this).attr("href").substr(1);
        var worker = workers[workerIndexMap[workerId]];
        
        var editName = worker.name;
        var prefix = "";
        if (!userCtx.isAdmin() && editName != userCtx.name && editName.substr(0, userCtx.name.length) == userCtx.name) {
            prefix = userCtx.name + "_";
            editName = editName.substr(userCtx.name.length + 1);
        }
        
        $.showDialog(templates.editWorkerDialog, {
            context: {
                edit: true,
                prefix: prefix,
                name: editName,
                disable_name: (!userCtx.isAdmin() && worker.name == editName),
                lp: (worker.lp === undefined ? true : worker.lp),
                lp_heartbeat: (worker.lp_heartbeat === undefined ? true : worker.lp_heartbeat)
            },
            submit: function (data, callback) {
                if (data.name == "") {
                    callback({name: "Please enter a name"});
                    return;
                }
                var newName = data.prefix + data.name;
                var newWorker = $.extend({}, worker);
                newWorker.lp = (data.lp ? undefined : false);
                newWorker.lp_heartbeat = (data.lp_heartbeat ? undefined : false);
                if (newName != worker.name) {
                    newWorker.name = newName;
                    confDb.view("workers/by_sub_pool_and_name", {
                        key: [doc._id, newName],
                        success: function (resp) {
                            if (resp.rows.length > 0)
                                callback({name: "Name is already taken"});
                            else
                                saveWorker(newWorker, callback);
                        }
                    });
                }
                else {
                    saveWorker(newWorker, callback);
                }
            }
        });
        
        return false;
    };
    
    function addWorker () {
        if (userCtx.userIdInSubpool(doc) === null) {
            userCtx.requestUserIdInSubpool(doc, {success: addWorker});
            return false;
        }
        
        var newWorker = {
            _id: $.couch.newUUID(),
            type: "worker",
            sub_pool_id: doc._id,
            user_id: userCtx.userIdInSubpool(doc)
        };
        
        if (workers.length == 0) {
            newWorker.name = userCtx.name;
            $.showDialog(templates.commonDialog, {
                context: {
                    title: "Create Default Worker",
                    help: "Welcome to ecoinpool!<br/><br/>Your default worker will be created now,<br/>you can configure it and add custom workers later."
                },
                submit: function (data, callback) {
                    saveWorker(newWorker, callback);
                }
            });
            
            return false;
        }
        
        $.showDialog(templates.editWorkerDialog, {
            context: {
                edit: false,
                prefix: (userCtx.isAdmin() ? "" : userCtx.name + "_"),
                lp: true,
                lp_heartbeat: true
            },
            submit: function (data, callback) {
                if (data.name == "") {
                    callback({name: "Please enter a name"});
                    return;
                }
                var newName = data.prefix + data.name;
                newWorker.name = newName;
                if (!data.lp)
                    newWorker.lp = false;
                if (!data.lp_heartbeat)
                    newWorker.lp_heartbeat = false;
                confDb.view("workers/by_sub_pool_and_name", {
                    key: [doc._id, newName],
                    success: function (resp) {
                        if (resp.rows.length > 0)
                            callback({name: "Name is already taken"});
                        else
                            saveWorker(newWorker, callback);
                    }
                });
            }
        });
        
        return false;
    };
    
    function renderWorkers (userId, tabTitle, canEditWorkers) {
        var aux = (doc.aux_pool !== undefined);
        var workerIds = [];
        var displayWorkers = $.map(workers, function (worker) {
            workerIds.push(worker._id);
            return {id: worker._id, name: worker.name, aux: aux};
        });
        
        var toolbuttons;
        if (canEditWorkers)
            toolbuttons = [{type: "add", title: "Add Worker", click: addWorker}];
        else
            toolbuttons = [];
        
        return {
            tab: {id: "workers", title: tabTitle, elt: $(templates.workersTable({aux: aux, workers: displayWorkers}))},
            toolbuttons: toolbuttons,
            init: function () {
                if (canEditWorkers)
                    $("#workers .content tr th a").click(editWorker);
                else
                    $("#workers .content tr th a").click(function () {alert("You cannot edit workers which don't belong to you."); return false;});
                $("#workers thead th .explain").click(function () {
                    alert("The left number are valid shares and the number after the plus are candidate shares (or winning shares).");
                    return false;
                });
                if (changes.main_db)
                    loadInitialWorkerStats(false, workerIds);
                if (changes.aux_db)
                    loadInitialWorkerStats(true, workerIds);
            }
        };
    };
    
    function startSharesMonitor (userId) {
        // Stop existing listeners
        if (changes.main_feed !== undefined) {
            changes.main_feed.stop();
            changes.main_feed = undefined;
        }
        if (changes.aux_feed !== undefined) {
            changes.aux_feed.stop();
            changes.aux_feed = undefined;
        }
        
        if (changes.main_db === undefined)
            return;
        
        changes.main_db.info({
            success: function (main_info) {
                changes.main_feed = changes.main_db.changes(main_info.update_seq, {
                    filter: "stats/shares_for_user",
                    include_docs: true,
                    user_id: userId
                });
                changes.main_feed.onChange(function (resp) {processChanges(resp, false);});
                
                if (changes.aux_db !== undefined) {
                    changes.aux_db.info({
                        success: function (aux_info) {
                            changes.aux_feed = changes.aux_db.changes(aux_info.update_seq, {
                                filter: "stats/shares_for_user",
                                include_docs: true,
                                user_id: userId
                            });
                            changes.aux_feed.onChange(function (resp) {processChanges(resp, true);});
                        }
                    });
                }
            }
        });
        
        speedUpdateTimer = setInterval(function () {
            var now = new Date();
            $.each(workers, function () {
                var shd = getWorkerShareData(this._id);
                var delta;
                if (shd.last_date) {
                    delta = now - shd.last_date;
                    if (delta > inactiveTimout && shd.active) {
                        shd.active = false;
                        displayWorkerActive(this._id, false);
                    }
                }
                if (shd.shares_per_minute_ts) {
                    delta = now - shd.shares_per_minute_ts;
                    if (delta > 60000) {
                        shd.shares_per_minute.shift();
                        shd.shares_per_minute.push(0);
                        shd.shares_per_minute_ts = now;
                        displayWorkerSpeed(this._id, shd);
                    }
                }
            });
        }, 1000);
    };
    
    function processChanges (resp, aux) {
        $.each(resp.results, function () {
            if (workerIndexMap[this.doc.worker_id] === undefined)
                return;
            
            var shd = getWorkerShareData(this.doc.worker_id);
            var now = new Date();
            
            if (aux) {
                if (this.doc.state == "invalid")
                    shd.aux_invalid++;
                else {
                    if (this.doc.state == "valid")
                        shd.aux_valid++;
                    else if (this.doc.state == "candidate")
                        shd.aux_candidate++;
                }
            }
            else {
                if (this.doc.state == "invalid")
                    shd.invalid++;
                else {
                    if (this.doc.state == "valid")
                        shd.valid++;
                    else if (this.doc.state == "candidate")
                        shd.candidate++;
                    
                    if (shd.shares_per_minute !== undefined)
                        shd.shares_per_minute[10] += 1;
                }
                
                shd.last_date = now;
                if (!shd.active) {
                    shd.active = true;
                    displayWorkerActive(this.doc.worker_id, true);
                }
            }
            
            displayWorkerShares(this.doc.worker_id, shd, aux);
        });
    };
    
    function getWorkerShareData (workerId) {
        var shd = workerShareData[workerId];
        if (shd === undefined) {
            shd = {invalid: 0, valid: 0, candidate: 0, aux_invalid: 0, aux_valid: 0, aux_candidate: 0};
            workerShareData[workerId] = shd;
        }
        return shd;
    };
    
    function loadInitialWorkerStats (aux, workerIds) {
        var db = (aux ? changes.aux_db : changes.main_db);
        var prefix = (aux ? "aux_" : "");
        // Load share counts
        db.view("stats/workers", {
            group: true,
            keys: workerIds,
            success: function (resp) {
                var resultWorkerIds = [];
                $.each(resp.rows, function () {
                    resultWorkerIds.push(this.key);
                    var shd = getWorkerShareData(this.key);
                    shd[prefix+"invalid"] = this.value[0];
                    shd[prefix+"valid"] = this.value[1];
                    shd[prefix+"candidate"] = this.value[2];
                    displayWorkerShares(this.key, shd, aux);
                });
                $.each(workerIds, function (index, workerId) {
                    if (resultWorkerIds.indexOf(workerId) == -1) {
                        displayWorkerShares(workerId, getWorkerShareData(workerId), aux);
                    }
                });
            }
        });
        // Load last share
        if (!aux) {
            db.view("timed_stats/worker_last_share", {
                group: true,
                keys: workerIds,
                success: function (resp) {
                    var resultWorkerIds = [];
                    $.each(resp.rows, function () {
                        resultWorkerIds.push(this.key);
                        var shd = getWorkerShareData(this.key);
                        shd.last_date = makeDateFromUTCArray(this.value[0]);
                        var delta = new Date() - shd.last_date;
                        shd.active = (delta < inactiveTimout);
                        displayWorkerActive(this.key, shd.active);
                    });
                    $.each(workerIds, function (index, workerId) {
                        if (resultWorkerIds.indexOf(workerId) == -1)
                            displayWorkerActive(workerId, false);
                    });
                }
            });
            // Load speed/shares per minute
            $.each(workerIds, function () {
                loadWorkerSharesPerMinute(this, getWorkerShareData(this), 11);
            });
        }
    };
    
    function loadWorkerSharesPerMinute (workerId, shd, intervals) {
        var ti = makeTimeIntervalKeys(new Date(), intervals);
        ti.startKey.splice(0, 0, workerId);
        ti.endKey.splice(0, 0, workerId);
        changes.main_db.view("timed_stats/valids_per_worker", {
            group_level: 6,
            startkey: ti.startKey,
            endkey: ti.endKey,
            success: function (resp) {
                var ts = makeDateFromUTCArray([ti.startKey[1], ti.startKey[2], ti.startKey[3], ti.startKey[4], ti.startKey[5], 0]).getTime();
                var result = [];
                $.each(resp.rows, function () {
                    var k_ts = makeDateFromUTCArray([this.key[1], this.key[2], this.key[3], this.key[4], this.key[5], 0]).getTime();
                    while (ts < k_ts) {
                        result.push(0);
                        ts += 60000;
                    }
                    result.push(this.value);
                    ts += 60000;
                });
                while (result.length < intervals) {
                    result.push(0);
                    ts += 60000;
                }
                shd.shares_per_minute = result;
                shd.shares_per_minute_ts = ts;
                displayWorkerSpeed(workerId, shd);
            }
        });
    };
    
    function displayWorkerShares (workerId, shd, aux) {
        var tr = $("#" + workerId);
        if (aux) {
            var sumShares = shd.aux_invalid + shd.aux_valid + shd.aux_candidate;
            if (sumShares == 0)
                tr.find(".aux_invalid").text("0");
            else
                tr.find(".aux_invalid").text(shd.aux_invalid + " (" + formatFloat(100 * shd.aux_invalid / sumShares, 4) + "%)");
            tr.find(".aux_valid").text(shd.aux_valid);
            tr.find(".aux_candidate").text(shd.aux_candidate);
        }
        else {
            var sumShares = shd.invalid + shd.valid + shd.candidate;
            if (sumShares == 0)
                tr.find(".invalid").text("0");
            else
                tr.find(".invalid").text(shd.invalid + " (" + formatFloat(100 * shd.invalid / sumShares, 4) + "%)");
            tr.find(".valid").text(shd.valid);
            tr.find(".candidate").text(shd.candidate);
        }
    };
    
    function displayWorkerSpeed (workerId, shd) {
        if (shd.shares_per_minute === undefined)
            return;
        var tr = $("#" + workerId);
        var s = 0;
        for (var i = 0; i < 10; i++)
            s += shd.shares_per_minute[i];
        s = s * thisPoolTypeInfo.hps / 600;
        tr.children(".speed").text(formatHashspeed(s));
    };
    
    function displayWorkerActive (workerId, active) {
        var tr = $("#" + workerId);
        var cell = tr.children(".active");
        if (active) {
            cell.addClass("yes");
            cell.text("Yes");
        }
        else {
            cell.removeClass("yes");
            cell.text("No");
        }
    };
    
    function displaySubpool (userId, userName, isSelf) {
        $("#content").empty();
        
        var toolbuttons = [];
        var tabs = [];
        var inits = [];
        
        if (doc._rev !== undefined) {
            var wrk = renderWorkers(userId, (isSelf ? "My Workers" : userName + "'s Workers"), isSelf && userCtx.isLoggedIn);
            $.merge(toolbuttons, wrk.toolbuttons);
            tabs.push(wrk.tab);
            inits.push(wrk.init);
        }
        
        if (userCtx.isAdmin()) {
            var cfg = renderSubpoolConfig();
            $.merge(toolbuttons, cfg.toolbuttons);
            tabs.push(cfg.tab);
            inits.push(cfg.init);
        }
        
        // Install the toolbar
        makeToolbar(toolbuttons);
        // Install all tabs
        pageTabs = new TabHandler(tabs);
        
        // Run init functions
        $.each(inits, function () {this();});
    };
    
    function saveSubpoolConfig () {
        // Write back all fields and validate
        doc.pool_type = getFieldValue("#pool_type");
        doc.name = getFieldValue("#name");
        if (doc.name === undefined) {
            $("#name input").focus();
            alert("Please enter a name!");
            return;
        }
        doc.port = getFieldValue("#port", true);
        if (doc.port <= 0 || doc.port >= 65536) {
            $("#port input").focus();
            alert("Please enter a valid port!");
            return;
        }
        doc.round = getFieldValue("#round", true);
        doc.max_cache_size = getFieldValue("#max_cache_size", true);
        doc.max_work_age = getFieldValue("#max_work_age", true);
        var aux_pool_type = getFieldValue("#aux_pool_type");
        if (aux_pool_type === undefined)
            doc.aux_pool = undefined;
        else {
            doc.aux_pool = {pool_type: aux_pool_type};
            doc.aux_pool.name = getFieldValue("#aux_pool_name");
            if (doc.name === undefined) {
                $("#aux_pool_name input").focus();
                alert("Please enter an aux pool name!");
                return;
            }
            doc.aux_pool.round = getFieldValue("#aux_pool_round", true);
            doc.aux_pool.aux_daemon = aux_daemon_config;
        }
        
        // Submit
        confDb.saveDoc(doc, {
            success: function (resp) {
                var path = location.href.split("/");
                var last = path[path.length-1];
                if (last == "subpool")
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
    
    function saveWorker (worker, callback) {
        confDb.saveDoc(worker, {
            success: function (resp) {
                if (workerIndexMap[worker._id] === undefined) {
                    if (workers.length == 0) { // Created first worker
                        location.reload();
                        return;
                    }
                    var aux = (doc.aux_pool !== undefined);
                    var odd = ($("#workers .content tr").length % 2 == 1);
                    $("#workers .content").append(templates.workerSingleRow({worker: {odd: odd, is_new: true, id: worker._id, name: worker.name, aux: aux}}));
                    var newRow = $("#workers .content tr:last");
                    newRow.find("th a").click(editWorker);
                    workerIndexMap[worker._id] = workers.length;
                    workers.push(worker);
                    $("#workers .footer td").text("​Showing " +  workers.length + " worker" + (workers.length != 1 ? "s" : ""));
                    var spm = []; for (var i = 0; i < 11; i++) spm.push(0);
                    $.extend(getWorkerShareData(worker._id), {shares_per_minute: spm, shares_per_minute_ts: new Date().getTime()});
                }
                else {
                    workers[workerIndexMap[worker._id]] = worker;
                    $("#" + worker._id + " th a").text(worker.name);
                }
                callback();
            },
            error: function (status, error, reason) {
                callback({name: reason});
            }
        });
    };
    
    function toggleSubpoolActivation () {
        var button = $(this);
        if (button.hasClass("load")) {
            if (mainConfig.active_subpools === undefined)
                mainConfig.active_subpools = [doc._id];
            else if ($.inArray(doc._id, mainConfig.active_subpools) == -1)
                mainConfig.active_subpools.push(doc._id);
        }
        else if (mainConfig.active_subpools !== undefined) {
            var pos = $.inArray(doc._id, mainConfig.active_subpools);
            if (pos != -1)
                mainConfig.active_subpools.splice(pos, 1);
        }
        
        confDb.saveDoc(mainConfig, {
            success: function (resp) {
                location.reload();
            },
            error: function (status, error, reason) {
                alert("The Subpool could not be toggled: " + reason);
            }
        });
    };
    
    // Add and select my navigation item
    sidebar.addMainNavItem(siteURL + "_show/subpool/" + (doc._rev === undefined ? '' : doc._id), (doc._rev === undefined ? "New Subpool" : doc.name), true);
    
    // Start by loading the main configuration
    confDb.openDoc("configuration", {
        success: function (conf) {
            mainConfig = conf;
            checkUserId();
        },
        error: function () {
            mainConfig = {_id: "configuration", type: "configuration"};
            checkUserId();
        }
    });
    
    // Second step: check the user ID
    function checkUserId () {
        if (doc._rev === undefined) { // New Subpool -> skip
            displaySubpool(null, null, false);
            return;
        }
        
        var userId = /[?&]user_id=([^&])/.exec(window.location.search);
        if (userId !== null) {
            userId = parseInt(userId[1]);
            if (isNaN(userId))
                userId = null;
        }
        
        var myUserId = userCtx.userIdInSubpool(doc);
        if (userId === null) {
            if (myUserId === null) { // No user ID -> render empty
                displaySubpool(null, null, true);
                return;
            }
            else {
                loadWorkers(myUserId, userCtx.name, true);
            }
        }
        else if (userId != myUserId) {
            usersDb.view("ecoinpool/user_names", {
                key: [doc._id, userId],
                success: function (resp) {
                    if (resp.rows.length == 0)
                        loadWorkers(userId, ""+userId, false);
                    else
                        loadWorkers(userId, resp.rows[0].value, false);
                }
            });
        }
        else {
            loadWorkers(userId, userCtx.name, true);
        }
    }
    
    // Third step: load the workers for the user
    function loadWorkers (userId, userName, isSelf) {
        confDb.view("workers/by_sub_pool_and_user_id", {
            key: [doc._id, userId],
            include_docs: true,
            success: function (resp) {
                workers = $.map(resp.rows, function (row, index) {
                    workerIndexMap[row.doc._id] = index;
                    return row.doc;
                });
                if (workers.length > 0) {
                    changes.main_db = $.couch.db(doc.name);
                    if (doc.aux_pool !== undefined)
                        changes.aux_db = $.couch.db(doc.aux_pool.name);
                    else
                        changes.aux_db = undefined;
                    
                    window.setTimeout(function () {startSharesMonitor(userId);}, 250);
                }
                displaySubpool(userId, userName, isSelf);
            }
        });
    };
});
