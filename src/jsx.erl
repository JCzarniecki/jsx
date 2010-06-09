%% The MIT License

%% Copyright (c) 2010 Alisdair Sullivan <alisdairsullivan@yahoo.ca>

%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:

%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.

%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%% THE SOFTWARE.



-module(jsx).
-author("alisdairsullivan@yahoo.ca").

-export([decode/1, decode/2, parser/0, parser/1, parser/2]).

-include("jsx_types.hrl").



-spec decode(JSON::json()) -> {ok, [jsx_event(),...]} | {error, badjson}.
-spec decode(JSON::json(), Opts::[any()]) -> {ok, [jsx_event(),...]} | {error, badjson}.

decode(JSON) ->
    decode(JSON, []).

decode(JSON, Opts) ->
    F = parser(Opts),
    case F(JSON) of
        {incomplete, _} -> {error, badjson}
        ; {error, badjson} -> {error, badjson}
        ; {Result, _} -> {ok, Result}
    end.
    

-spec parser() -> jsx_parser().
-spec parser(Opts::[any()]) -> jsx_parser().
-spec parser(Callbacks::{fun((jsx_event(), any()) -> any())}, Opts::[any()]) -> jsx_parser()
    ; (Callbacks::{atom(), atom(), any()}, Opts::[any()]) -> jsx_parser().

parser() ->
    parser([]).

parser(Opts) ->
    F = fun(end_of_json, State) -> lists:reverse(State) 
            ; (reset, _State) -> []
            ; (Event, State) -> [Event] ++ State
        end,
    parser({F, []}, Opts).

parser({F, _} = Callbacks, OptsList) when is_list(OptsList), is_function(F) ->
    start(Callbacks, OptsList);
parser({Mod, Fun, State}, OptsList) when is_list(OptsList), is_atom(Mod), is_atom(Fun) ->
    start({fun(E, S) -> Mod:Fun(E, S) end, State}, OptsList).


start(Callbacks, OptsList) ->
    F = case proplists:get_value(encoding, OptsList, auto) of
        utf8 -> fun jsx_utf8:start/4
        ; utf16 -> fun jsx_utf16:start/4
        ; utf32 -> fun jsx_utf32:start/4
        ; {utf16, little} -> fun jsx_utf16le:start/4
        ; {utf32, little} -> fun jsx_utf32le:start/4
        ; auto -> fun detect_encoding/4
    end,
    start(Callbacks, OptsList, F).
    
start(Callbacks, OptsList, F) ->
    Opts = parse_opts(OptsList),
    fun(Stream) -> F(Stream, [], Callbacks, Opts) end.


parse_opts(Opts) ->
    parse_opts(Opts, {false, codepoint, false}).

parse_opts([], Opts) ->
    Opts;    
parse_opts([{comments, Value}|Rest], {_Comments, EscapedUnicode, Stream}) ->
    true = lists:member(Value, [true, false]),
    parse_opts(Rest, {Value, EscapedUnicode, Stream});
parse_opts([{escaped_unicode, Value}|Rest], {Comments, _EscapedUnicode, Stream}) ->
    true = lists:member(Value, [ascii, codepoint, none]),
    parse_opts(Rest, {Comments, Value, Stream});
parse_opts([{stream_mode, Value}|Rest], {Comments, EscapedUnicode, _Stream}) ->
    true = lists:member(Value, [true, false]),
    parse_opts(Rest, {Comments, EscapedUnicode, Value});
parse_opts([_UnknownOpt|Rest], Opts) ->
    parse_opts(Rest, Opts).
    
    
%% first check to see if there's a bom, if not, use the rfc4627 method for determining
%%   encoding. this function makes some assumptions about the validity of the stream
%%   which may delay failure later than if an encoding is explicitly provided.    
    
%% utf8 bom detection    
detect_encoding(<<16#ef, 16#bb, 16#bf, Rest/binary>>, Stack, Callbacks, Opts) ->
    jsx_utf8:start(Rest, Stack, Callbacks, Opts);    
    
%% utf32-little bom detection (this has to come before utf16-little)
detect_encoding(<<16#ff, 16#fe, 0, 0, Rest/binary>>, Stack, Callbacks, Opts) ->
    jsx_utf32le:start(Rest, Stack, Callbacks, Opts);    
    
%% utf16-big bom detection
detect_encoding(<<16#fe, 16#ff, Rest/binary>>, Stack, Callbacks, Opts) ->
    jsx_utf16:start(Rest, Stack, Callbacks, Opts);
    
%% utf16-little bom detection
detect_encoding(<<16#ff, 16#fe, Rest/binary>>, Stack, Callbacks, Opts) ->
    jsx_utf16le:start(Rest, Stack, Callbacks, Opts);
    
%% utf32-big bom detection
detect_encoding(<<0, 0, 16#fe, 16#ff, Rest/binary>>, Stack, Callbacks, Opts) ->
    jsx_utf32:start(Rest, Stack, Callbacks, Opts);
    

%% utf32-little null order detection
detect_encoding(<<X, 0, 0, 0, _Rest/binary>> = JSON, Stack, Callbacks, Opts) when X =/= 0 ->
    jsx_utf32le:start(JSON, Stack, Callbacks, Opts);
    
%% utf16-big null order detection
detect_encoding(<<0, X, 0, Y, _Rest/binary>> = JSON, Stack, Callbacks, Opts) when X =/= 0, Y =/= 0 ->
    jsx_utf16:start(JSON, Stack, Callbacks, Opts);
    
%% utf16-little null order detection
detect_encoding(<<X, 0, Y, 0, _Rest/binary>> = JSON, Stack, Callbacks, Opts) when X =/= 0, Y =/= 0 ->
    jsx_utf16le:start(JSON, Stack, Callbacks, Opts);

%% utf32-big null order detection
detect_encoding(<<0, 0, 0, X, _Rest/binary>> = JSON, Stack, Callbacks, Opts) when X =/= 0 ->
    jsx_utf32:start(JSON, Stack, Callbacks, Opts);
    
%% utf8 null order detection
detect_encoding(<<X, Y, _Rest/binary>> = JSON, Stack, Callbacks, Opts) when X =/= 0, Y =/= 0 ->
    jsx_utf8:start(JSON, Stack, Callbacks, Opts);
    
%% a problem, to autodetect naked single digits' encoding, there is not enough data
%%   to conclusively determine the encoding correctly. below is an attempt to solve
%%   the problem

detect_encoding(<<X>>, Stack, Callbacks, Opts) when X =/= 0 ->
    {try {Result, _} = jsx_utf8:start(<<X>>, [], Callbacks, Opts), Result 
        catch error:function_clause -> incomplete end,
        fun(Stream) ->
            detect_encoding(<<X, Stream/binary>>, Stack, Callbacks, Opts)
        end
    };
detect_encoding(<<0, X>>, Stack, Callbacks, Opts) when X =/= 0 ->
    {try {Result, _} = jsx_utf16:start(<<0, X>>, [], Callbacks, Opts), Result 
        catch error:function_clause -> incomplete end,
        fun(Stream) ->
            detect_encoding(<<0, X, Stream/binary>>, Stack, Callbacks, Opts)
        end
    };
detect_encoding(<<X, 0>>, Stack, Callbacks, Opts) when X =/= 0 ->
    {try {Result, _} = jsx_utf16le:start(<<X, 0>>, [], Callbacks, Opts), Result 
        catch error:function_clause -> incomplete end,
        fun(Stream) ->
            detect_encoding(<<X, 0, Stream/binary>>, Stack, Callbacks, Opts)
        end
    };
    
%% not enough input, request more
detect_encoding(Bin, Stack, Callbacks, Opts) ->
    {incomplete, 
        fun(Stream) -> 
            detect_encoding(<<Bin/binary, Stream/binary>>, Stack, Callbacks, Opts) 
        end
    }.