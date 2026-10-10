module Column.TodoSeq exposing
    ( TodoSeqColumn
    , addTaskItem
    , containsTask
    , decoder
    , defaultKeyword
    , encoder
    , id
    , init
    , initWithKind
    , isCollapsed
    , isWritable
    , keywords
    , kind
    , name
    , primaryValue
    , setCollapse
    , setTagsToHide
    , tagsToHide
    , toList
    , toggleCollapse
    , updateName
    )

import Date exposing (Date)
import PlacementResult exposing (PlacementResult)
import TaskItem exposing (TaskItem)
import TaskList exposing (TaskList)
import Time
import TsJson.Decode as TsDecode
import TsJson.Decode.Pipeline as TsDecode
import TsJson.Encode as TsEncode


type TodoSeqColumn
    = TodoSeqColumn Config (List String) TaskList


type alias Config =
    { closedBucket : Maybe String
    , collapsed : Bool
    , columnType : String
    , dailyNoteBucket : Maybe String
    , deadlineBucket : Maybe String
    , defaultKeyword : Maybe String
    , group : Maybe String
    , id : String
    , kind : String
    , keywords : List String
    , name : String
    , priority : Maybe String
    , scheduledBucket : Maybe String
    , sourceBucket : Maybe String
    , sourceValue : Maybe String
    , subtaskProgress : Maybe String
    , tag : Maybe String
    , urgencyBucket : Maybe String
    , writable : Bool
    }


init : String -> String -> List String -> Maybe String -> Maybe String -> TodoSeqColumn
init id_ name_ keywords_ group_ defaultKeyword_ =
    initWithKind id_ name_ "state" keywords_ group_ defaultKeyword_


initWithKind : String -> String -> String -> List String -> Maybe String -> Maybe String -> TodoSeqColumn
initWithKind id_ name_ kind_ keywords_ group_ defaultKeyword_ =
    TodoSeqColumn
        (configFromParts id_ name_ kind_ keywords_ group_ defaultKeyword_ False)
        []
        TaskList.empty


decoder : TsDecode.Decoder TodoSeqColumn
decoder =
    (TsDecode.succeed configFromDecodedFields
        |> TsDecode.required "id" TsDecode.string
        |> TsDecode.required "name" TsDecode.string
        |> TsDecode.optional "kind" TsDecode.string "state"
        |> TsDecode.required "keywords" (TsDecode.list TsDecode.string)
        |> TsDecode.required "group" (TsDecode.maybe TsDecode.string)
        |> TsDecode.required "defaultKeyword" (TsDecode.maybe TsDecode.string)
        |> TsDecode.required "collapsed" TsDecode.bool
        |> TsDecode.required "columnType" TsDecode.string
        |> TsDecode.optional "writable" TsDecode.bool False
    )
        |> TsDecode.map (\c -> TodoSeqColumn c [] TaskList.empty)


encoder : TsEncode.Encoder TodoSeqColumn
encoder =
    TsEncode.map config configEncoder


containsTask : String -> TodoSeqColumn -> Bool
containsTask taskId (TodoSeqColumn _ _ tl) =
    TaskList.containsTask taskId tl


defaultKeyword : TodoSeqColumn -> Maybe String
defaultKeyword (TodoSeqColumn c _ _) =
    c.defaultKeyword


id : TodoSeqColumn -> String
id (TodoSeqColumn c _ _) =
    c.id


isCollapsed : TodoSeqColumn -> Bool
isCollapsed (TodoSeqColumn c _ _) =
    c.collapsed


isWritable : TodoSeqColumn -> Bool
isWritable (TodoSeqColumn c _ _) =
    c.writable


kind : TodoSeqColumn -> String
kind (TodoSeqColumn c _ _) =
    c.kind


keywords : TodoSeqColumn -> List String
keywords (TodoSeqColumn c _ _) =
    c.keywords


name : TodoSeqColumn -> String
name (TodoSeqColumn c _ _) =
    c.name


primaryValue : TodoSeqColumn -> Maybe String
primaryValue (TodoSeqColumn c _ _) =
    case c.kind of
        "keywordGroup" ->
            c.group

        "priority" ->
            c.priority

        "scheduledBucket" ->
            c.scheduledBucket

        "deadlineBucket" ->
            c.deadlineBucket

        "closedBucket" ->
            c.closedBucket

        "tag" ->
            c.tag

        "urgencyBucket" ->
            c.urgencyBucket

        "dailyNote" ->
            c.dailyNoteBucket

        "source" ->
            c.sourceValue

        "subtaskProgress" ->
            c.subtaskProgress

        _ ->
            List.head c.keywords


tagsToHide : TodoSeqColumn -> List String
tagsToHide (TodoSeqColumn _ tth _) =
    tth


toList : TodoSeqColumn -> List TaskItem
toList (TodoSeqColumn _ _ tl) =
    tl
        |> TaskList.topLevelTasks
        |> List.sortBy TaskItem.todoSeqSortKey


addTaskItem : TaskItem -> TodoSeqColumn -> ( TodoSeqColumn, PlacementResult )
addTaskItem taskItem ((TodoSeqColumn c tth tl) as todoSeqColumn) =
    if belongs c taskItem then
        ( TodoSeqColumn c tth (TaskList.add taskItem tl), PlacementResult.Placed )

    else
        ( todoSeqColumn, PlacementResult.DoesNotBelong )


setCollapse : Bool -> TodoSeqColumn -> TodoSeqColumn
setCollapse isCollapsed_ (TodoSeqColumn c tth tl) =
    TodoSeqColumn { c | collapsed = isCollapsed_ } tth tl


setTagsToHide : List String -> TodoSeqColumn -> TodoSeqColumn
setTagsToHide tags (TodoSeqColumn c _ tl) =
    TodoSeqColumn c tags tl


toggleCollapse : TodoSeqColumn -> TodoSeqColumn
toggleCollapse (TodoSeqColumn c tth tl) =
    TodoSeqColumn { c | collapsed = not c.collapsed } tth tl


updateName : String -> TodoSeqColumn -> TodoSeqColumn
updateName newName (TodoSeqColumn c tth tl) =
    TodoSeqColumn { c | name = newName } tth tl


config : TodoSeqColumn -> Config
config (TodoSeqColumn c _ _) =
    c


configEncoder : TsEncode.Encoder Config
configEncoder =
    TsEncode.object
        [ TsEncode.required "id" .id TsEncode.string
        , TsEncode.required "collapsed" .collapsed TsEncode.bool
        , TsEncode.required "name" .name TsEncode.string
        , TsEncode.required "columnType" .columnType TsEncode.string
        , TsEncode.required "kind" .kind TsEncode.string
        , TsEncode.required "match" identity matchEncoder
        , TsEncode.required "keywords" .keywords (TsEncode.list TsEncode.string)
        , TsEncode.required "group" .group (TsEncode.maybe TsEncode.string)
        , TsEncode.required "defaultKeyword" .defaultKeyword (TsEncode.maybe TsEncode.string)
        , TsEncode.required "writable" .writable TsEncode.bool
        ]


configFromParts : String -> String -> String -> List String -> Maybe String -> Maybe String -> Bool -> Config
configFromParts id_ name_ kind_ keywords_ group_ defaultKeyword_ collapsed_ =
    let
        keyword : Maybe String
        keyword =
            List.head keywords_
    in
    { closedBucket =
        if kind_ == "closedBucket" then
            keyword

        else
            Nothing
    , collapsed = collapsed_
    , columnType = columnTypeForKind kind_
    , dailyNoteBucket =
        if kind_ == "dailyNote" then
            keyword

        else
            Nothing
    , deadlineBucket =
        if kind_ == "deadlineBucket" then
            keyword

        else
            Nothing
    , defaultKeyword = defaultKeyword_
    , group = group_
    , id = id_
    , kind = kind_
    , keywords = keywords_
    , name = name_
    , priority =
        if kind_ == "priority" then
            keyword

        else
            Nothing
    , scheduledBucket =
        if kind_ == "scheduledBucket" then
            keyword

        else
            Nothing
    , sourceBucket = Nothing
    , sourceValue = Nothing
    , subtaskProgress =
        if kind_ == "subtaskProgress" then
            keyword

        else
            Nothing
    , tag =
        if kind_ == "tag" then
            keyword

        else
            Nothing
    , urgencyBucket =
        if kind_ == "urgencyBucket" then
            keyword

        else
            Nothing
    , writable = isWritableKind kind_ defaultKeyword_
    }


configFromDecodedFields : String -> String -> String -> List String -> Maybe String -> Maybe String -> Bool -> String -> Bool -> Config
configFromDecodedFields id_ name_ kind_ keywords_ group_ defaultKeyword_ collapsed_ columnType_ writable_ =
    let
        c : Config
        c =
            configFromParts id_ name_ kind_ keywords_ group_ defaultKeyword_ collapsed_
    in
    { c | columnType = columnType_, writable = writable_ || isWritableKind kind_ defaultKeyword_ }


columnTypeForKind : String -> String
columnTypeForKind kind_ =
    case kind_ of
        "state" ->
            "keyword"

        "keywordGroup" ->
            "group"

        _ ->
            "custom"


isWritableKind : String -> Maybe String -> Bool
isWritableKind kind_ defaultKeyword_ =
    case kind_ of
        "state" ->
            defaultKeyword_ /= Nothing

        "keywordGroup" ->
            defaultKeyword_ /= Nothing

        "priority" ->
            True

        _ ->
            False


belongs : Config -> TaskItem -> Bool
belongs c taskItem =
    case c.kind of
        "state" ->
            List.member (TaskItem.todoSeqState taskItem) c.keywords

        "keywordGroup" ->
            TaskItem.todoSeqGroup taskItem == c.group

        "priority" ->
            c.priority == Just (Maybe.withDefault "none" (TaskItem.todoSeqPriority taskItem))

        "scheduledBucket" ->
            c.scheduledBucket == Just (dateBucket (TaskItem.todoSeqScheduledDateMillis taskItem))

        "deadlineBucket" ->
            c.deadlineBucket == Just (dateBucket (TaskItem.todoSeqDeadlineDateMillis taskItem))

        "closedBucket" ->
            c.closedBucket == Just (closedBucket (TaskItem.todoSeqClosedDateMillis taskItem))

        "tag" ->
            case c.tag of
                Just tag_ ->
                    List.member (normalizeTag tag_) (List.map normalizeTag (TaskItem.todoSeqTags taskItem))

                Nothing ->
                    False

        "urgencyBucket" ->
            c.urgencyBucket == Just (urgencyBucket (TaskItem.todoSeqUrgency taskItem))

        "dailyNote" ->
            c.dailyNoteBucket
                == Just
                    (if TaskItem.todoSeqIsDailyNote taskItem then
                        "daily"

                     else
                        "notDaily"
                    )

        "source" ->
            case ( c.sourceBucket, c.sourceValue ) of
                ( Just "file", Just value ) ->
                    (TaskItem.todoSeqSource taskItem).file == value

                ( Just "folder", Just value ) ->
                    (TaskItem.todoSeqSource taskItem).file == value || String.startsWith (String.dropRight 1 value ++ "/") (TaskItem.todoSeqSource taskItem).file

                _ ->
                    False

        "subtaskProgress" ->
            c.subtaskProgress == Just (subtaskProgressBucket (TaskItem.todoSeqSubtaskProgress taskItem))

        _ ->
            List.member (TaskItem.todoSeqState taskItem) c.keywords


dateBucket : Maybe Int -> String
dateBucket maybeMillis =
    case maybeMillis of
        Nothing ->
            "none"

        Just millis ->
            if Date.toRataDie (Date.fromPosix Time.utc (Time.millisToPosix millis)) < Date.toRataDie (Date.fromPosix Time.utc (Time.millisToPosix 0)) then
                "overdue"

            else if Date.toRataDie (Date.fromPosix Time.utc (Time.millisToPosix millis)) == Date.toRataDie (Date.fromPosix Time.utc (Time.millisToPosix 0)) then
                "today"

            else if Date.toRataDie (Date.fromPosix Time.utc (Time.millisToPosix millis)) <= Date.toRataDie (Date.fromPosix Time.utc (Time.millisToPosix 0)) + 7 then
                "upcoming"

            else
                "future"


closedBucket : Maybe Int -> String
closedBucket maybeMillis =
    case maybeMillis of
        Nothing ->
            "open"

        Just _ ->
            "closed"


urgencyBucket : Maybe Float -> String
urgencyBucket urgency =
    case urgency of
        Nothing ->
            "none"

        Just value ->
            if value <= 0 then
                "none"

            else if value >= 10 then
                "high"

            else if value >= 5 then
                "medium"

            else
                "low"


subtaskProgressBucket : { completed : Int, total : Int } -> String
subtaskProgressBucket progress =
    if progress.total <= 0 then
        "none"

    else if progress.completed <= 0 then
        "notStarted"

    else if progress.completed >= progress.total then
        "complete"

    else
        "inProgress"


normalizeTag : String -> String
normalizeTag tag_ =
    if String.startsWith "#" tag_ then
        String.dropLeft 1 tag_

    else
        tag_


matchEncoder : TsEncode.Encoder Config
matchEncoder =
    TsEncode.object
        [ TsEncode.required "states" .keywords (TsEncode.list TsEncode.string)
        , TsEncode.required "group" .group (TsEncode.maybe TsEncode.string)
        , TsEncode.required "priority" .priority (TsEncode.maybe TsEncode.string)
        , TsEncode.required "scheduledBucket" .scheduledBucket (TsEncode.maybe TsEncode.string)
        , TsEncode.required "deadlineBucket" .deadlineBucket (TsEncode.maybe TsEncode.string)
        , TsEncode.required "closedBucket" .closedBucket (TsEncode.maybe TsEncode.string)
        , TsEncode.required "tag" .tag (TsEncode.maybe TsEncode.string)
        , TsEncode.required "urgencyBucket" .urgencyBucket (TsEncode.maybe TsEncode.string)
        , TsEncode.required "subtaskProgress" .subtaskProgress (TsEncode.maybe TsEncode.string)
        ]
