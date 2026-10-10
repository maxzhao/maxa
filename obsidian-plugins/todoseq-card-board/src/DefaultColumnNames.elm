module DefaultColumnNames exposing
    ( DefaultColumnNames
    , default
    , encoder
    , nameFor
    , v_0_10_0_decoder
    , v_0_11_0_decoder
    , v_0_12_0_decoder
    , v_0_13_0_decoder
    , v_0_7_0_decoder
    , v_0_8_0_decoder
    , v_0_9_0_decoder
    )

import TsJson.Decode as TsDecode
import TsJson.Encode as TsEncode



-- TYPES


type alias DefaultColumnNames =
    { inactive : Maybe String
    , active : Maybe String
    , waiting : Maybe String
    , completed : Maybe String
    , archived : Maybe String
    , today : Maybe String
    , tomorrow : Maybe String
    , future : Maybe String
    , undated : Maybe String
    , otherTags : Maybe String
    , untagged : Maybe String
    }


default : DefaultColumnNames
default =
    { inactive = Nothing
    , active = Nothing
    , waiting = Nothing
    , completed = Nothing
    , archived = Nothing
    , today = Nothing
    , tomorrow = Nothing
    , future = Nothing
    , undated = Nothing
    , otherTags = Nothing
    , untagged = Nothing
    }



-- INFO


nameFor : String -> DefaultColumnNames -> String
nameFor column defaultColumnNames =
    case column of
        "inactive" ->
            Maybe.withDefault "Inactive" defaultColumnNames.inactive

        "active" ->
            Maybe.withDefault "Active" defaultColumnNames.active

        "waiting" ->
            Maybe.withDefault "Waiting" defaultColumnNames.waiting

        "completed" ->
            Maybe.withDefault "Completed" defaultColumnNames.completed

        "archived" ->
            Maybe.withDefault "Archived" defaultColumnNames.archived

        "today" ->
            Maybe.withDefault "Today" defaultColumnNames.today

        "tomorrow" ->
            Maybe.withDefault "Tomorrow" defaultColumnNames.tomorrow

        "future" ->
            Maybe.withDefault "Future" defaultColumnNames.future

        "undated" ->
            Maybe.withDefault "Undated" defaultColumnNames.undated

        "otherTags" ->
            Maybe.withDefault "Other Tags" defaultColumnNames.otherTags

        "untagged" ->
            Maybe.withDefault "Untagged" defaultColumnNames.untagged

        _ ->
            ""



-- SERIALIZE


v_0_13_0_decoder : TsDecode.Decoder DefaultColumnNames
v_0_13_0_decoder =
    v_0_12_0_decoder


v_0_12_0_decoder : TsDecode.Decoder DefaultColumnNames
v_0_12_0_decoder =
    v_0_11_0_decoder


encoder : TsEncode.Encoder DefaultColumnNames
encoder =
    TsEncode.object
        [ TsEncode.required "inactive" (fromMaybe .inactive) TsEncode.string
        , TsEncode.required "active" (fromMaybe .active) TsEncode.string
        , TsEncode.required "waiting" (fromMaybe .waiting) TsEncode.string
        , TsEncode.required "completed" (fromMaybe .completed) TsEncode.string
        , TsEncode.required "archived" (fromMaybe .archived) TsEncode.string
        , TsEncode.required "today" (fromMaybe .today) TsEncode.string
        , TsEncode.required "tomorrow" (fromMaybe .tomorrow) TsEncode.string
        , TsEncode.required "future" (fromMaybe .future) TsEncode.string
        , TsEncode.required "undated" (fromMaybe .undated) TsEncode.string
        , TsEncode.required "otherTags" (fromMaybe .otherTags) TsEncode.string
        , TsEncode.required "untagged" (fromMaybe .untagged) TsEncode.string
        ]



-- LEGACY


v_0_11_0_decoder : TsDecode.Decoder DefaultColumnNames
v_0_11_0_decoder =
    TsDecode.succeed DefaultColumnNames
        |> TsDecode.andMap (TsDecode.field "inactive" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "active" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "waiting" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "completed" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "archived" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "today" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "tomorrow" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "future" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "undated" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "otherTags" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "untagged" <| TsDecode.map toMaybe TsDecode.string)


v_0_10_0_decoder : TsDecode.Decoder DefaultColumnNames
v_0_10_0_decoder =
    v_0_9_0_decoder


v_0_9_0_decoder : TsDecode.Decoder DefaultColumnNames
v_0_9_0_decoder =
    v_0_8_0_decoder


v_0_8_0_decoder : TsDecode.Decoder DefaultColumnNames
v_0_8_0_decoder =
    v_0_7_0_decoder


v_0_7_0_decoder : TsDecode.Decoder DefaultColumnNames
v_0_7_0_decoder =
    TsDecode.succeed legacyColumnNames
        |> TsDecode.andMap (TsDecode.field "today" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "tomorrow" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "future" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "undated" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "others" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "untagged" <| TsDecode.map toMaybe TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "completed" <| TsDecode.map toMaybe TsDecode.string)



-- PRIVATE


legacyColumnNames : Maybe String -> Maybe String -> Maybe String -> Maybe String -> Maybe String -> Maybe String -> Maybe String -> DefaultColumnNames
legacyColumnNames today tomorrow future undated others untagged completed =
    { inactive = Nothing
    , active = Nothing
    , waiting = Nothing
    , completed = completed
    , archived = Nothing
    , today = today
    , tomorrow = tomorrow
    , future = future
    , undated = undated
    , otherTags = others
    , untagged = untagged
    }


fromMaybe : (DefaultColumnNames -> Maybe String) -> DefaultColumnNames -> String
fromMaybe mapper =
    Maybe.withDefault "" << mapper


toMaybe : String -> Maybe String
toMaybe s =
    if String.length s == 0 then
        Nothing

    else
        Just s
