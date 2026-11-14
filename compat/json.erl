-module(json).

-export([
    encode/1,
    decode/1
]).

encode(Data) ->
    jsx:encode(Data).

decode(Binary) ->
    jsx:decode(Binary, [return_maps]).
