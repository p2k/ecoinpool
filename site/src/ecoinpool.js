
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

/*
 * This file uses portions of Futon, CouchDB's web interface, released under the
 * following license:
 * 
 * Licensed under the Apache License, Version 2.0 (the "License"); you may not
 * use this file except in compliance with the License. You may obtain a copy of
 * the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
 * WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
 * License for the specific language governing permissions and limitations under
 * the License.
 */

Handlebars.registerHelper('plural_s', function (value) {
    return (value == 1 ? "" : "s");
});

Handlebars.registerHelper('ifequal', function (a, b, fn, inverse) {
    if (a == b)
        return fn(this);
    else
        return inverse(this);
});

Handlebars.registerHelper('form_field', function (field) {
    var ret = "";
    var hasValue = (field.value !== undefined);
    var fieldName = (field.name !== undefined ? ' name="' + field.name + '"' : '');
    switch (field.type) {
        case "text":
        case "password":
            ret = '<input type="' + field.type + '"' + fieldName + ' spellcheck="false"';
            if (field.size !== undefined)
                ret += ' size="' + field.size + '"';
            if (field.placeholder !== undefined)
                ret += ' placeholder="' + field.placeholder + '"';
            ret += (hasValue ? ' value="' + field.value + '" />' : ' />');
            break;
        case "select":
            ret = '<select' + fieldName + '>';
            for (var i = 0; i < field.options.length; i++) {
                var option = field.options[i];
                ret += '<option value="' + option.value + '"' + (hasValue && field.value == option.value ? ' selected="selected">' : '>') + option.title + '</option>';
            }
            ret += '</select>';
            break;
        case "check":
            ret = '<input type="checkbox"' + fieldName + (field.checked ? ' checked="checked"' : '') + ' />';
            break;
        case "extended":
            ret = '<button>' + field.label + '</button> <span class="descr">' + field.value + '</span>';
            break;
    }
    if (field.optional !== undefined)
        ret = '<p class="default"><input type="radio" ' + (hasValue ? '/> ' : ' checked="checked" /> ') + '<label>' + field.optional + '</label></p>' + 
              '<p class="custom"><input type="radio" ' + (hasValue ? ' checked="checked" /> ' : '/> ') + ret;
    if (field.suffix !== undefined)
        ret += ' ' + field.suffix;
    if (field.optional !== undefined)
        ret += '</p>'
    return ret;
});

Handlebars.registerHelper('each_striped', function (context, fn, inverse) {
    var ret = "";
    
    if (context && context.length > 0) {
        for (var i=0, j=context.length; i<j; i++) {
            var item = context[i];
            item.odd = (i % 2 == 1);
            item.even = !item.odd;
            ret = ret + fn(item);
        }
    } else {
        ret = inverse(this);
    }
    
    return ret;
});

function formatFloat (value, decimals) {
    var f = Math.pow(10, decimals);
    var s = "" + (Math.round(value*f)/f);
    var spl = s.split(".");
    if (spl.length == 1)
        return s + "." + (new Array(decimals+1).join("0"));
    else if (spl[1].length == decimals)
        return s;
    else if (spl[1].length > decimals)
        return s.substr(0, s.length - (spl[1].length - decimals));
    else
        return s + (new Array(decimals - spl[1].length + 1).join("0"));
};

function formatHashspeed (speed) {
    if (speed >= 1000000000)
        return formatFloat(speed / 1000000000, 2) + " GH/s";
    else if (speed >= 1000000)
        return formatFloat(speed / 1000000, 2) + " MH/s";
    else if (speed > 1000)
        return formatFloat(speed / 1000, 2) + " kH/s";
    else
        return formatFloat(speed, 2) + " H/s";
};

function makeDateFromUTCArray (adate) {
    return new Date(Date.UTC(adate[0], adate[1]-1, adate[2], adate[3], adate[4], adate[5]));
};

function makeUTCArrayFromDate (date) {
    return [date.getUTCFullYear(), date.getUTCMonth()+1, date.getUTCDate(), date.getUTCHours(), date.getUTCMinutes(), date.getUTCSeconds()];
};

function makeTimeIntervalKeys (startDate, minutes) {
    var endDate = new Date(startDate.getTime() - minutes * 60000 + 60000);
    var ret = {
        endKey: makeUTCArrayFromDate(startDate),
        startKey: makeUTCArrayFromDate(endDate)
    };
    ret.endKey[5] = 59;
    ret.startKey[5] = 0;
    return ret;
};

function installFieldsLogic (selector, addLogic) {
    addLogic = addLogic || {};
    $(selector).each(function () {
        var elt = $(this);
        
        var l = addLogic[elt.attr("id")];
        if (l !== undefined) {
            if (l.button_click !== undefined)
                elt.find("button:first").click(l.button_click);
            if (l.link_click !== undefined)
                elt.find("a:first").click(l.link_click);
            if (l.select_change !== undefined)
                elt.find("select:first").change(l.select_change);
            if (l.text_input_keydown !== undefined)
                elt.find('input[type="text"]:first').keydown(l.text_input_keydown);
        }
        
        var d = elt.find("p.default");
        var c = elt.find("p.custom");
        if (d.length == 0 || c.length == 0)
            return;
        
        var dr = d.find("input:first");
        var cr = c.find("input:first");
        var dfn = function () {
            cr.removeAttr("checked");
            dr.attr("checked", "checked");
        };
        var cfn = function () {
            dr.removeAttr("checked");
            cr.attr("checked", "checked");
        };
        
        dr.click(dfn);
        dr.next().click(dfn);
        cr.click(cfn);
        cr.next().focus(cfn);
    });
}

function setFieldEnabled (selector, enabled) {
    var field = $(selector);
    
    if (enabled) {
        field.parent().removeClass("disabled");
        field.find("input, select, button").removeAttr("disabled");
    }
    else {
        field.parent().addClass("disabled");
        field.find("input, select, button").attr("disabled", "disabled");
    }
}

function getFieldValue (selector, integer) {
    var field = $(selector);
    
    var ret;
    var d = field.find("p.default");
    if (d.length != 0) {
        if (d.find("input:first:checked").length != 0)
            ret = undefined;
        else
            ret = field.find("p.custom").find("input:first").next().val();
    }
    else {
        ret = field.find("input:first, select:first").val();
    }
    
    if (ret === "") {
        ret = undefined;
    }
    
    if (integer && ret !== undefined) {
        ret = parseInt(ret);
    }
    
    return ret;
}

function filterIntegerOnly (evt) {
    if (
        (!evt.shiftKey && evt.which >= 48 && evt.which <= 57) || // Normal numbers
        (!evt.shiftKey && evt.which >= 96 && evt.which <= 105) || // Numpad
        (evt.which >= 37 && evt.which <= 40) || // Arrows
        evt.which == 8 || evt.which == 46 || evt.which == 16 || // Backspace, Delete, Shift
        evt.which == 17 || evt.ctrlKey || evt.which == 91 || evt.metaKey || // Control, Meta
        evt.which == 35 || evt.which == 36 // Home, End
        )
        return;
    
    evt.preventDefault();
    evt.stopPropagation();
}

function UserContext (data, callbacks) {
    this._callbacks = [];
    this.isEmpty = $.isEmptyObject(data);
    this.isLoggedIn = (this.isEmpty ? false : data.name !== null);
    if (!this.isEmpty)
        $.extend(this, data);
    
    this.ready = function (callback) {
        this._callbacks.push(callback);
        if (!this.isEmpty)
            callback();
    };
    
    this.isAdmin = function () {
        return $.inArray("_admin", this.roles) != -1;
    };
    
    this.userIdInSubpool = function (subPoolDoc) {
        var user_id = null;
        $.each(this.roles, function () {
            var spl = this.split(":")
            if (spl[0] != "user_id")
                return true;
            if (spl[1] == subPoolDoc._id) {
                user_id = parseInt(spl[2]);
                return false;
            }
            return true;
        });
        return user_id;
    };
    
    this.requestUserIdInSubpool = function (subPoolDoc, options) {
        var self = this;
        options = options || {};
        var url = 'http://' + location.hostname + ':' + subPoolDoc.port + '/';
        var data = {method: "setup_user", id: 1, params: [this.name]};
        $.ajax({
            type: "GET", url: url, dataType: "jsonp", data: data,
            beforeSend: function (xhr) {
                xhr.setRequestHeader('Accept', 'application/json');
            },
            success: function (resp) {
                if (resp.error) {
                    if (options.error)
                        options.error(status, resp.error);
                    else
                        alert("An error occurred while requesting a user ID: " + resp.error.message);
                }
                else {
                    var userId = resp.result;
                    self.roles.push("user_id:" + subPoolDoc._id + ":" + userId);
                    if (options.success) options.success(userId);
                }
            },
            error: function (xhr) {
                if (xhr.getResponseHeader("content-type") == "text/javascript" && xhr.responseText != "")
                    jQuery.httpData(xhr, this.dataType, this);
                else {
                    if (options.error)
                        options.error(status);
                    else
                        alert("An unknown error occurred while requesting a user ID.");
                }
            }
        });
    };
    
    this.newContext = function (data) {
        return new UserContext(data, this._callbacks);
    };
    
    if (!$.isEmptyObject(callbacks)) {
        $.each(callbacks, function () {this();});
        this._callbacks = callbacks;
    }
}

function TabHandler (tabs) {
    var self = this;
    this.ul = $('<ul id="tabs"></ul>');
    $("#content").append(this.ul);
    this.tabs = {};
    this.activeTabId = undefined;
    
    function deactivateActiveTab () {
        if (self.activeTabId === undefined) return;
        var tab = self.tabs[self.activeTabId];
        tab.li.removeClass("active");
        tab.elt.hide();
    };
    
    this.activateTab = function (id) {
        deactivateActiveTab();
        var tab = this.tabs[id];
        tab.li.addClass("active");
        tab.elt.show();
        this.activeTabId = id;
    };
    
    this.replaceTabElement = function (id, elt) {
        var tab = this.tabs[id];
        if (tab.elt.is(":visible"))
            elt.show();
        else
            elt.hide();
        tab.elt.replaceWith(elt);
        tab.elt = elt;
    };
    
    $.each(tabs, function (index) {
        var id = this.id;
        var li = $('<li></li>');
        var a = $('<a href="#' + id + '">' + this.title + '</a>');
        a.click(function () {self.activateTab(id); return false;});
        li.append(a);
        self.ul.append(li);
        if (this.active) {
            li.addClass("active");
            this.elt.show();
            self.activeTabId = id;
        }
        else
            this.elt.hide();
        $("#content").append(this.elt);
        self.tabs[id] = {index: index, title: this.title, li: li, elt: this.elt};
    });
    
    if (this.activeTabId === undefined && tabs.length > 0) {
        this.activateTab(tabs[0].id);
    }
}

function makeToolbar (items) {
    var toolbar = $('<ul id="toolbar"></ul>');
    
    if (items !== undefined && typeof items != "string") {
        $.each(items, function () {
            var li = $('<li></li>');
            var button = $('<button>' + this.title + '</button>');
            if (this.type)
                button.addClass(this.type);
            if (this.href) {
                var buttonHref = this.href;
                button.click(function () {window.location.href = buttonHref;});
            }
            else if (this.click) {
                button.click(this.click);
            }
            li.append(button);
            toolbar.append(li);
        });
    }
    else if (typeof items == "string") {
        toolbar.append('<li>' + items + '</li>');
    }
    else {
        toolbar.append('<li>&nbsp;</li>');
    }
    
    var oldToolbar = $("#toolbar");
    if (oldToolbar.length == 0)
        $("#content").append(toolbar);
    else
        oldToolbar.replaceWith(toolbar);
}

var userCtx = new UserContext();
var sidebar;
var siteURL = "/ecoinpool/_design/site/";
var usersDb;
var confDb = $.couch.db("ecoinpool");
var ebitcoinDb = $.couch.db("ebitcoin");

var templates = {};

$(document).ready(function () {
    
    function SidebarHandler (elt) {
        this.elt = elt;
        this.userCtxElt = elt.find("#userCtx");
        
        /* Private methods */
        function doLogin (name, password, callback) {
            $.couch.login({
                name: name,
                password: password,
                success: function () {
                    getSessionInfo();
                    callback();
                },
                error: function (code, error, reason) {
                    callback({name: "Error logging in: "+reason});
                }
            });
        };
        
        function doSignup (name, password, callback, runLogin) {
            $.couch.signup({
                name: name
            }, password, {
                success: function () {
                    if (runLogin) {
                        doLogin(name, password, callback);            
                    } else {
                        callback();
                    }
                },
                error: function (status, error, reason) {
                    if (error == "conflict") {
                        callback({name: "Name '"+name+"' is taken"});
                    } else {
                        callback({name: "Signup error: "+reason});
                    }
                }
            });
        };
        
        function validateUsernameAndPassword (data, callback) {
            if (!data.name || data.name.length == 0) {
                callback({name: "Please enter a name."});
                return false;
            }
            
            return validatePassword(data, callback);
        };
    
        function validatePassword (data, callback) {
            if (!data.password || data.password.length == 0) {
                callback({password: "Please enter a password."});
                return false;
            }
            return true;
        };
        
        /* Public methods */
        this.login = function () {
            $.showDialog(templates.commonDialog, {
                context: {
                    title: "Login",
                    help: "Login to ecoinpool with your name and password.",
                    fields: [
                        {name: "name", label: "Username:", type: "text", size: 24},
                        {name: "password", label: "Password:", type: "password", size: 24}
                    ],
                    submit: "Login"
                },
                submit: function (data, callback) {
                    if (!validateUsernameAndPassword(data, callback)) return;
                    doLogin(data.name, data.password, callback);
                }
            });
            
            return false;
        };
        
        this.logout = function () {
            $.couch.logout({
                success : function (resp) {
                    getSessionInfo();
                }
            });
            
            return false;
        };
        
        this.signup = function () {
            $.showDialog(templates.commonDialog, {
                context: {
                    title: "Create User Account",
                    help: "Create an user account on this ecoinpool server.<br/>You will be logged in as this user after the account has been created.",
                    fields: [
                        {name: "name", label: "Username:", type: "text", size: 24},
                        {name: "password", label: "Password:", type: "password", size: 24}
                    ],
                    submit: "Create"
                },
                submit: function (data, callback) {
                    if (!validateUsernameAndPassword(data, callback)) return;
                    doSignup(data.name, data.password, callback, true);
                }
            });
            
            return false;
        };
    
        this.changePassword = function () {
            $.showDialog(templates.commonDialog, {
                context: {
                    title: "Change Password",
                    fields: [
                        {name: "password", label: "New Password:", type: "password", size: 24},
                        {name: "verify_password", label: "Verify New Password:", type: "password", size: 24}
                    ],
                    submit: "Change"
                },
                submit: function (data, callback) {
                    if (validatePassword(data, callback)) {
                        if (data.password != data.verify_password) {
                            callback({verify_password: "Passwords don't match."});
                            return false;
                        }
                    } else {
                        return false;
                    }
                    
                    $.couch.session({success: function (resp) {
                        if (resp.userCtx.roles.indexOf("_admin") > -1) {
                            $.couch.config({
                                success: function () {
                                    doLogin(resp.userCtx.name, data.password, function(errors) {
                                        if (!$.isEmptyObject(errors)) {
                                            callback(errors);
                                            return;
                                        } else {
                                            location.reload();
                                        }
                                    });
                                }
                            }, "admins", resp.userCtx.name, data.password);
                        } else {
                            $.couch.db(resp.info.authentication_db).openDoc("org.couchdb.user:"+resp.userCtx.name, {
                                success: function (user) {
                                    $.couch.db(resp.info.authentication_db).saveDoc($.couch.prepareUserDoc(user, data.password), {
                                        success: function () {
                                            doLogin(user.name, data.password, function(errors) {
                                                if(!$.isEmptyObject(errors)) {
                                                    callback(errors);
                                                    return;
                                                } else {
                                                    location.reload();
                                                }
                                            });
                                        }
                                    });
                                }
                            });
                        }
                    }});
                    
                    return true;
                }
            });
            return false;
        };
        
        this.setUserName = function (name) {
            this.userCtxElt.find(".name").text(name).show();
        };
        
        this.setLoggedIn = function (loggedin) {
            if (loggedin) {
                this.userCtxElt.find(".loggedout").hide();
                this.userCtxElt.find(".loggedin").show();
            }
            else {
                this.userCtxElt.find(".loggedin").hide();
                this.userCtxElt.find(".loggedout").show();
            }
        };
        
        this.addMainNavItem = function (url, title, selected) {
            var mainNav = this.elt.find("#nav li:first");
            if (mainNav.find('ul > li > a[href="' + url + '"]').length > 0)
                return; // Ignore if already added
            if (selected)
                mainNav.addClass("selected");
            mainNav.children("ul").append('<li' + (selected ? ' class="selected"' : '') + '><a href="' + url + '">' + title + '</a></li>');
        };
        
        this.selectMainNavItem = function (name) {
            var mainNav = this.elt.find("#nav li:first");
            mainNav.addClass("selected");
            mainNav.find("ul > li > a").each(function () {
                var elt = $(this);
                if (elt.attr("href").match("/"+name+"$") !== null) {
                    elt.parent().addClass("selected");
                    return false;
                }
                return true;
            });
        };
        
        // Install DOM element
        $("#wrap").append(elt);
        
        // Install click event handlers
        this.userCtxElt.find(".login").click(this.login);
        this.userCtxElt.find(".logout").click(this.logout);
        this.userCtxElt.find(".signup").click(this.signup);
        this.userCtxElt.find(".changepass").click(this.changePassword);
        
        // Get CouchDB version
        $.couch.info({
            success: function (info, status) {
                $("#version").text(info.version);
            }
        });
    }
    
    function getSessionInfo () {
        $.couch.session({
            success: function (r) {
                usersDb = $.couch.db(r.info.authentication_db);
                userCtx = userCtx.newContext(r.userCtx);
                if (userCtx.isLoggedIn) {
                    sidebar.setUserName(userCtx.name);
                    sidebar.setLoggedIn(true);
                } else {
                    sidebar.setLoggedIn(false);
                };
            }
        });
    };
    
    // Do main setup & install sidebar
    $.ajax({
        url: siteURL + "templates.html",
        type: "GET",
        cache: true,
        dataType: "html",
        success: function (resp) {
            // Compile partials & templates
            $(resp).each(function () {
                var template = $(this);
                if (!template.is("script") || template.attr("type") != "text/x-handlebars-template")
                    return;
                var nameType = template.attr("id").split("-");
                var templateHtml = template.html();
                if (nameType[1] == "partial")
                    Handlebars.registerPartial(nameType[0], templateHtml);
                else if (nameType[1] == "template")
                    templates[nameType[0]] = Handlebars.compile(templateHtml);
            });
            
            $("body").removeClass("loading");
            
            $(document)
                .ajaxStart(function () { $("body").addClass("loading"); })
                .ajaxStop(function () { $("body").removeClass("loading"); });
            
            sidebar = new SidebarHandler($(templates.sidebar({})));
            
            // Get session info
            getSessionInfo();
        }
    });
});
