#!/usr/bin/env escript

parse_commandline(Cmd) ->
    parse_commandline(Cmd, undefined, {[], [], "site.json"}).

parse_commandline([], _, Acc) ->
    Acc;
parse_commandline([H|T], Mode, Acc={Loaders, Resources, Target}) ->
    case H of
        "--loaders" ->
            parse_commandline(T, loaders, Acc);
        "--resources" ->
            parse_commandline(T, resources, Acc);
        "--target" ->
            parse_commandline(T, target, Acc);
        _ ->
            case Mode of
                undefined ->
                    io:format("Warning: argument \"~s\" ignored.", [H]),
                    parse_commandline(T, Mode, Acc);
                loaders ->
                    parse_commandline(T, Mode, {Loaders ++ [H], Resources, Target});
                resources ->
                    parse_commandline(T, Mode, {Loaders, Resources ++ [H], Target});
                target ->
                    parse_commandline(T, Mode, {Loaders, Resources, H})
            end
    end.


make_loader(Filename) ->
    [LoaderName|_] = string:tokens(filename:basename(Filename), "."),
    {ok, IoDev} = file:open(Filename, [read, raw, binary, {read_ahead, 160}]),
    {ok, TailCleaner} = re:compile("[ \t\n]+$"),
    {ok, HeadCleaner} = re:compile("^[ \t]+"),
    CleanedLoader = make_loader(IoDev, TailCleaner, HeadCleaner, false, <<>>),
    ok = file:close(IoDev),
    {list_to_binary(LoaderName), CleanedLoader}.

make_loader(IoDev, TailCleaner, HeadCleaner, Brace, Acc) ->
    case file:read_line(IoDev) of
        eof ->
            Acc;
        {ok, Line} ->
            Cleaned1 = re:replace(Line, TailCleaner, <<>>, [{return, binary}]),
            F = binary:first(Cleaned1),
            R = if
                F =:= $}; Brace -> <<>>;
                true -> <<" ">>
            end,
            Cleaned2 = re:replace(Cleaned1, HeadCleaner, R, [{return, binary}]),
            make_loader(IoDev, TailCleaner, HeadCleaner, binary:last(Cleaned2) =:= ${, <<Acc/binary, Cleaned2/binary>>)
    end.


make_attachment(Filename) ->
    Key = list_to_binary(filename:basename(Filename)),
    {ok, Content} = file:read_file(Filename),
    {Key, {[
        {<<"content_type">>, mime_type(Filename)},
        {<<"data">>, base64:encode(Content)}
    ]}}.


mime_type(Filename) ->
    case filename:extension(Filename) of
        ".js" -> <<"application/x-javascript">>;
        ".html" -> <<"text/html">>;
        ".css" -> <<"text/css">>;
        ".png" -> <<"image/png">>
    end.


write_json(Filename, {DocProps}) ->
    {ok, IoDev} = file:open(Filename, [write, raw]),
    try
        ok = file:write(IoDev, <<"{\n">>),
        EscapePattern = binary:compile_pattern([<<"\"">>, <<"\\">>]),
        ok = write_json(IoDev, 3, EscapePattern, DocProps),
        ok = file:write(IoDev, <<"}">>)
    after
        file:close(IoDev)
    end.

write_json(_, _, _, []) ->
    ok;
write_json(IoDev, Indent, EscapePattern, [{K, V}|T]) ->
    ok = file:write(IoDev, [lists:duplicate(Indent, 32), $", K, $", ": "]),
    case V of
        {Props} when is_list(Props) ->
            ok = file:write(IoDev, <<"{\n">>),
            ok = write_json(IoDev, Indent + 4, EscapePattern, Props),
            ok = file:write(IoDev, [lists:duplicate(Indent, 32), $}]);
        _ when is_binary(V) ->
            ok = file:write(IoDev, <<"\"">>),
            ok = file:write(IoDev, binary:replace(V, EscapePattern, <<"\\">>, [global, {insert_replaced, 1}])),
            ok = file:write(IoDev, <<"\"">>)
    end,
    case T of
        [] ->
            file:write(IoDev, <<"\n">>);
        _ ->
            file:write(IoDev, <<",\n">>),
            write_json(IoDev, Indent, EscapePattern, T)
    end.


main(Cmd) ->
    {Loaders, Resources, Target} = parse_commandline(Cmd),
    Doc = {[
        {<<"_id">>, <<"_design/site">>},
        {<<"language">>, <<"javascript">>},
        {<<"shows">>, {[make_loader(X) || X <- Loaders]}},
        {<<"_attachments">>, {[make_attachment(X) || X <- Resources]}}
    ]},
    write_json(Target, Doc).
