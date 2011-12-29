function (doc, req) {
    var name;
    if (doc === null) {
        name = "New Subpool";
        if (req.id)
            return {code: 404, body: "Subpool not found!"};
        if (req.userCtx.roles.indexOf('_admin') === -1)
            return {code: 403, body: "Only admins can create new Subpools!"};
    }
    else {
        if (doc.type != "sub-pool")
            return {code: 406, body: "This is not a Subpool ID!"};
        name = doc.name;
    }
    return ['<?xml version="1.0" encoding="UTF-8"?>',
        '<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">',
        '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en">',
        '<head>',
        '  <title>ecoinpool - ' + name + '</title>',
        '  <meta http-equiv="content-type" content="application/xhtml+xml; charset=UTF-8" />',
        '  <link rel="stylesheet" href="../../style.css" type="text/css">',
        '  <script type="text/javascript" src="../../handlebars.1.0.0.beta.3.js"></script>',
        '  <script type="text/javascript" src="/_utils/script/jquery.js"></script>',
        '  <script type="text/javascript" src="/_utils/script/jquery.couch.js"></script>',
        '  <script type="text/javascript" src="../../jquery.dialog.js"></script>',
        '  <script type="text/javascript" src="/_utils/script/sha1.js"></script>',
        '  <script type="text/javascript">',
        '    var db_info = ' + JSON.stringify(req.info) + ';',
        '    var doc = ' + (doc === null ? '{"_id": "' + req.uuid + '", "type": "sub-pool"}' : JSON.stringify(doc)) + ';',
        '  </script>',
        '  <script type="text/javascript" src="../../ecoinpool.js"></script>',
        '  <script type="text/javascript" src="../../subpool.js"></script>',
        '</head>',
        '<body class="loading">',
        '  <div id="wrap">',
        '    <h1><a href="../home">ecoinpool</a><strong>' + name + '</strong></h1>',
        '    <div id="content"><p>Loading...</p></div>',
        '  </div>',
        '</body>',
        '</html>'].join("\n");
}