-module(load_examples).

-export([load/0]).

-spec load() -> ok | {error, term()}.
load() ->
    Files = filelib:wildcard("examples/*.erl"),
    load_files(Files).

-spec load_files([file:filename()]) -> ok | {error, term()}.
load_files([]) ->
    ok;
load_files([File | Rest]) ->
    case compile:file(File, [binary, debug_info, return_errors]) of
        {ok, Module, Binary} ->
            case code:load_binary(Module, File, Binary) of
                {module, Module} ->
                    load_files(Rest);
                {error, Reason} ->
                    {error, {load_failed, File, Reason}}
            end;
        {ok, Module, Binary, _Warnings} ->
            case code:load_binary(Module, File, Binary) of
                {module, Module} ->
                    load_files(Rest);
                {error, Reason} ->
                    {error, {load_failed, File, Reason}}
            end;
        {error, Errors, Warnings} ->
            {error, {compile_failed, File, Errors, Warnings}}
    end.
