function (doc, req) {
    var urlPrefix = "";
    var siteURL = "../../";
    var name;
    if (doc === null) {
        name = "New Client";
        if (req.id)
            return {code: 404, body: "Client not found!"};
        if (req.userCtx.roles.indexOf('_admin') === -1)
            return {code: 403, body: "Only admins can create new Clients!"};
    }
    else {
        if (doc.type != "client")
            return {code: 406, body: "This is not a Client ID!"};
        if (doc.title !== undefined)
            name = doc.title;
        else
            name = doc.name;
    }
    return ['<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">',
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">',
        '<head>',
        '  <title>ebitcoin - ' + name + '</title>',
        '  <meta http-equiv="content-type" content="application/xhtml+xml; charset=UTF-8" />',
        '  <link rel="stylesheet" href="' + siteURL + 'style.css" type="text/css">',
        '  <script type="text/javascript" src="' + siteURL + 'handlebars.1.0.0.beta.3.js"></script>',
        '  <script type="text/javascript" src="' + siteURL + 'jquery.js"></script>',
        '  <script type="text/javascript" src="' + siteURL + 'jquery.couch.js"></script>',
        '  <script type="text/javascript" src="' + siteURL + 'jquery.dialog.js"></script>',
        '  <script type="text/javascript" src="' + siteURL + 'sha1.js"></script>',
        '  <script type="text/javascript">',
        '    $.couch.urlPrefix = "' + urlPrefix + '";',
        '    var siteURL = "' + siteURL + '";',
        '    var db_info = ' + JSON.stringify(req.info) + ';',
        '    var doc = ' + (doc === null ? '{"_id": "' + req.uuid + '", "type": "client"}' : JSON.stringify(doc)) + ';',
        '  </script>',
        '  <script type="text/javascript" src="' + siteURL + 'common.js"></script>',
        '  <script type="text/javascript" src="' + siteURL + 'client.js"></script>',
        '</head>',
        '<body class="loading">',
        '  <div id="wrap">',
        '    <h1><a href="../home">ebitcoin</a><strong>' + name + '</strong></h1>',
        '    <div id="content"><p>Loading...</p></div>',
        '  </div>',
        '</body>',
        '</html>'].join("\n");
}