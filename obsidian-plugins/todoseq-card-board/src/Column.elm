module Column exposing
    ( Column(..)
    , addTaskItem
    , asCompletedColumn
    , cardCount
    , cards
    , completed
    , containsTask
    , dated
    , decoder
    , defaultKeyword
    , encoder
    , id
    , isCollapsed
    , isCompleted
    , isWritable
    , name
    , namedTag
    , namedTagTag
    , otherTags
    , setCollapse
    , setNameToDefault
    , setTagsToHide
    , todoSeq
    , todoSeqWithKind
    , toggleCollapse
    , typeString
    , undated
    , untagged
    , updateName
    , updateOtherTags
    )

import Card exposing (Card)
import Column.Completed as CompletedColumn exposing (CompletedColumn)
import Column.Dated as DatedColumn exposing (DatedColumn)
import Column.NamedTag as NamedTagColumn exposing (NamedTagColumn)
import Column.OtherTags as OtherTagsColumn exposing (OtherTagsColumn)
import Column.TodoSeq as TodoSeqColumn exposing (TodoSeqColumn)
import Column.Undated as UndatedColumn exposing (UndatedColumn)
import Column.Untagged as UntaggedColumn exposing (UntaggedColumn)
import Date exposing (Date)
import DecodeHelpers
import DefaultColumnNames exposing (DefaultColumnNames)
import PlacementResult exposing (PlacementResult)
import TaskItem exposing (TaskItem)
import TsJson.Decode as TsDecode
import TsJson.Encode as TsEncode



-- TYPES


type Column
    = Completed CompletedColumn
    | Dated DatedColumn
    | NamedTag NamedTagColumn
    | OtherTags OtherTagsColumn
    | TodoSeq TodoSeqColumn
    | Undated UndatedColumn
    | Untagged UntaggedColumn



-- CONSTRUCTION


completed : CompletedColumn -> Column
completed =
    Completed


dated : DatedColumn -> Column
dated =
    Dated


namedTag : String -> String -> Column
namedTag name_ tag_ =
    NamedTag <| NamedTagColumn.init name_ tag_


otherTags : String -> List String -> Column
otherTags name_ ots =
    OtherTags <| OtherTagsColumn.init name_ ots


todoSeq : String -> String -> List String -> Maybe String -> Maybe String -> Column
todoSeq id_ name_ keywords_ group_ defaultKeyword_ =
    TodoSeq <| TodoSeqColumn.init id_ name_ keywords_ group_ defaultKeyword_


todoSeqWithKind : String -> String -> String -> String -> Column
todoSeqWithKind name_ kind_ value_ id_ =
    let
        safeValue : String
        safeValue =
            if String.trim value_ == "" then
                String.trim name_

            else
                String.trim value_

        group : Maybe String
        group =
            if kind_ == "keywordGroup" then
                Just safeValue

            else
                Nothing

        keywords : List String
        keywords =
            if kind_ == "source" then
                []

            else
                [ safeValue ]

        defaultKeyword_ : Maybe String
        defaultKeyword_ =
            if kind_ == "state" then
                Just safeValue

            else
                Nothing
    in
    TodoSeq <| TodoSeqColumn.initWithKind id_ name_ kind_ keywords group defaultKeyword_


undated : String -> Column
undated name_ =
    Undated <| UndatedColumn.init name_


untagged : String -> Column
untagged name_ =
    Untagged <| UntaggedColumn.init name_



-- DECODE / ENCODE


decoder : TsDecode.Decoder Column
decoder =
    TsDecode.oneOf
        [ DecodeHelpers.toElmVariant "completed" Completed CompletedColumn.decoder
        , DecodeHelpers.toElmVariant "dated" Dated DatedColumn.decoder
        , DecodeHelpers.toElmVariant "namedTag" NamedTag NamedTagColumn.decoder
        , DecodeHelpers.toElmVariant "otherTags" OtherTags OtherTagsColumn.decoder
        , DecodeHelpers.toElmVariant "todoSeq" TodoSeq TodoSeqColumn.decoder
        , DecodeHelpers.toElmVariant "undated" Undated UndatedColumn.decoder
        , DecodeHelpers.toElmVariant "untagged" Untagged UntaggedColumn.decoder
        ]


encoder : TsEncode.Encoder Column
encoder =
    TsEncode.union
        (\vCompleted vDated vNamedTag vOtherTags vTodoSeq vUndated vUntagged value ->
            case value of
                Completed config ->
                    vCompleted config

                Dated config ->
                    vDated config

                NamedTag config ->
                    vNamedTag config

                OtherTags config ->
                    vOtherTags config

                TodoSeq config ->
                    vTodoSeq config

                Undated config ->
                    vUndated config

                Untagged config ->
                    vUntagged config
        )
        |> TsEncode.variantTagged "completed" CompletedColumn.encoder
        |> TsEncode.variantTagged "dated" DatedColumn.encoder
        |> TsEncode.variantTagged "namedTag" NamedTagColumn.encoder
        |> TsEncode.variantTagged "otherTags" OtherTagsColumn.encoder
        |> TsEncode.variantTagged "todoSeq" TodoSeqColumn.encoder
        |> TsEncode.variantTagged "undated" UndatedColumn.encoder
        |> TsEncode.variantTagged "untagged" UntaggedColumn.encoder
        |> TsEncode.buildUnion



-- INFO


asCompletedColumn : Column -> Maybe CompletedColumn
asCompletedColumn column =
    case column of
        Completed completedColumn ->
            Just completedColumn

        _ ->
            Nothing


cardCount : Column -> Int
cardCount column =
    List.length (toList column)


cards : String -> Column -> List Card
cards boardId column =
    let
        cardIdPrefix : String
        cardIdPrefix =
            boardId ++ ":" ++ name column
    in
    toList column
        |> List.map (Card.fromTaskItem cardIdPrefix (tagsToHide column))


defaultKeyword : Column -> Maybe String
defaultKeyword column =
    case column of
        TodoSeq todoSeqColumn ->
            TodoSeqColumn.defaultKeyword todoSeqColumn

        _ ->
            Nothing


isWritable : Column -> Bool
isWritable column =
    case column of
        TodoSeq todoSeqColumn ->
            TodoSeqColumn.isWritable todoSeqColumn

        _ ->
            False


id : Column -> String
id column =
    case column of
        TodoSeq todoSeqColumn ->
            TodoSeqColumn.id todoSeqColumn

        _ ->
            name column


containsTask : String -> Column -> Bool
containsTask taskId column =
    case column of
        Completed completedColumn ->
            CompletedColumn.containsTask taskId completedColumn

        Dated datedColumn ->
            DatedColumn.containsTask taskId datedColumn

        NamedTag namedTagColumn ->
            NamedTagColumn.containsTask taskId namedTagColumn

        OtherTags otherTagsColumn ->
            OtherTagsColumn.containsTask taskId otherTagsColumn

        TodoSeq todoSeqColumn ->
            TodoSeqColumn.containsTask taskId todoSeqColumn

        Undated undatedColumn ->
            UndatedColumn.containsTask taskId undatedColumn

        Untagged untaggedColumn ->
            UntaggedColumn.containsTask taskId untaggedColumn


isCollapsed : Column -> Bool
isCollapsed column =
    case column of
        Completed completedColumn ->
            CompletedColumn.isCollapsed completedColumn

        Dated datedColumn ->
            DatedColumn.isCollapsed datedColumn

        NamedTag namedTagColumn ->
            NamedTagColumn.isCollapsed namedTagColumn

        OtherTags otherTagsColumn ->
            OtherTagsColumn.isCollapsed otherTagsColumn

        TodoSeq todoSeqColumn ->
            TodoSeqColumn.isCollapsed todoSeqColumn

        Undated undatedColumn ->
            UndatedColumn.isCollapsed undatedColumn

        Untagged untaggedColumn ->
            UntaggedColumn.isCollapsed untaggedColumn


isCompleted : Column -> Bool
isCompleted column =
    case column of
        Completed _ ->
            True

        _ ->
            False


name : Column -> String
name column =
    case column of
        Completed completedColumn ->
            CompletedColumn.name completedColumn

        Dated datedColumn ->
            DatedColumn.name datedColumn

        NamedTag namedTagColumn ->
            NamedTagColumn.name namedTagColumn

        OtherTags otherTagsColumn ->
            OtherTagsColumn.name otherTagsColumn

        TodoSeq todoSeqColumn ->
            TodoSeqColumn.name todoSeqColumn

        Undated undatedColumn ->
            UndatedColumn.name undatedColumn

        Untagged untaggedColumn ->
            UntaggedColumn.name untaggedColumn


namedTagTag : Column -> Maybe String
namedTagTag column =
    case column of
        NamedTag namedTagColumn ->
            Just (NamedTagColumn.tag namedTagColumn)

        _ ->
            Nothing


typeString : Column -> String
typeString column =
    case column of
        Completed _ ->
            "Completed"

        Dated _ ->
            "Dated"

        NamedTag _ ->
            "Tagged"

        OtherTags _ ->
            "Other Tags"

        TodoSeq _ ->
            "TODOseq"

        Undated _ ->
            "Undated"

        Untagged _ ->
            "Untagged"



-- MANIPULATION


addTaskItem : Date -> TaskItem -> Column -> ( Column, PlacementResult )
addTaskItem today taskItem column =
    case column of
        Completed _ ->
            ( column, PlacementResult.DoesNotBelong )

        Dated datedColumn ->
            DatedColumn.addTaskItem today taskItem datedColumn
                |> Tuple.mapFirst Dated

        NamedTag namedTagColumn ->
            NamedTagColumn.addTaskItem taskItem namedTagColumn
                |> Tuple.mapFirst NamedTag

        OtherTags otherTagsColumn ->
            OtherTagsColumn.addTaskItem taskItem otherTagsColumn
                |> Tuple.mapFirst OtherTags

        TodoSeq todoSeqColumn ->
            TodoSeqColumn.addTaskItem taskItem todoSeqColumn
                |> Tuple.mapFirst TodoSeq

        Undated undatedColumn ->
            UndatedColumn.addTaskItem taskItem undatedColumn
                |> Tuple.mapFirst Undated

        Untagged untaggedColumn ->
            UntaggedColumn.addTaskItem taskItem untaggedColumn
                |> Tuple.mapFirst Untagged


setCollapse : Bool -> Column -> Column
setCollapse isCollapsed_ column =
    case column of
        Completed completedColumn ->
            Completed (CompletedColumn.setCollapse isCollapsed_ completedColumn)

        Dated datedColumn ->
            Dated (DatedColumn.setCollapse isCollapsed_ datedColumn)

        NamedTag namedTagColumn ->
            NamedTag (NamedTagColumn.setCollapse isCollapsed_ namedTagColumn)

        OtherTags otherTagsColumn ->
            OtherTags (OtherTagsColumn.setCollapse isCollapsed_ otherTagsColumn)

        TodoSeq todoSeqColumn ->
            TodoSeq (TodoSeqColumn.setCollapse isCollapsed_ todoSeqColumn)

        Undated undatedColumn ->
            Undated (UndatedColumn.setCollapse isCollapsed_ undatedColumn)

        Untagged untaggedColumn ->
            Untagged (UntaggedColumn.setCollapse isCollapsed_ untaggedColumn)


setNameToDefault : DefaultColumnNames -> Column -> Column
setNameToDefault defaultColumnNames column =
    case column of
        Completed completedColumn ->
            Completed (CompletedColumn.setNameToDefault defaultColumnNames completedColumn)

        Dated datedColumn ->
            Dated (DatedColumn.setNameToDefault defaultColumnNames datedColumn)

        NamedTag _ ->
            column

        OtherTags otherTagsColumn ->
            OtherTags (OtherTagsColumn.setNameToDefault defaultColumnNames otherTagsColumn)

        TodoSeq _ ->
            column

        Undated undatedColumn ->
            Undated (UndatedColumn.setNameToDefault defaultColumnNames undatedColumn)

        Untagged untaggedColumn ->
            Untagged (UntaggedColumn.setNameToDefault defaultColumnNames untaggedColumn)


setTagsToHide : List String -> Column -> Column
setTagsToHide tags column =
    case column of
        Completed completedColumn ->
            Completed (CompletedColumn.setTagsToHide tags completedColumn)

        Dated datedColumn ->
            Dated (DatedColumn.setTagsToHide tags datedColumn)

        NamedTag namedTagColumn ->
            NamedTag (NamedTagColumn.setTagsToHide tags namedTagColumn)

        OtherTags otherTagsColumn ->
            OtherTags (OtherTagsColumn.setTagsToHide tags otherTagsColumn)

        TodoSeq todoSeqColumn ->
            TodoSeq (TodoSeqColumn.setTagsToHide tags todoSeqColumn)

        Undated undatedColumn ->
            Undated (UndatedColumn.setTagsToHide tags undatedColumn)

        Untagged untaggedColumn ->
            Untagged (UntaggedColumn.setTagsToHide tags untaggedColumn)


toggleCollapse : Column -> Column
toggleCollapse column =
    case column of
        Completed completedColumn ->
            Completed (CompletedColumn.toggleCollapse completedColumn)

        Dated datedColumn ->
            Dated (DatedColumn.toggleCollapse datedColumn)

        NamedTag namedTagColumn ->
            NamedTag (NamedTagColumn.toggleCollapse namedTagColumn)

        OtherTags otherTagsColumn ->
            OtherTags (OtherTagsColumn.toggleCollapse otherTagsColumn)

        TodoSeq todoSeqColumn ->
            TodoSeq (TodoSeqColumn.toggleCollapse todoSeqColumn)

        Undated undatedColumn ->
            Undated (UndatedColumn.toggleCollapse undatedColumn)

        Untagged untaggedColumn ->
            Untagged (UntaggedColumn.toggleCollapse untaggedColumn)


updateName : String -> Column -> Column
updateName newName column =
    case column of
        Completed completedColumn ->
            Completed (CompletedColumn.updateName newName completedColumn)

        Dated datedColumn ->
            Dated (DatedColumn.updateName newName datedColumn)

        NamedTag namedTagColumn ->
            NamedTag (NamedTagColumn.updateName newName namedTagColumn)

        OtherTags otherTagsColumn ->
            OtherTags (OtherTagsColumn.updateName newName otherTagsColumn)

        TodoSeq todoSeqColumn ->
            TodoSeq (TodoSeqColumn.updateName newName todoSeqColumn)

        Undated undatedColumn ->
            Undated (UndatedColumn.updateName newName undatedColumn)

        Untagged untaggedColumn ->
            Untagged (UntaggedColumn.updateName newName untaggedColumn)


updateOtherTags : (OtherTagsColumn -> OtherTagsColumn) -> Column -> Column
updateOtherTags fn column =
    case column of
        OtherTags otherTagsColumn ->
            OtherTags <| fn otherTagsColumn

        _ ->
            column



-- PRIVATE


tagsToHide : Column -> List String
tagsToHide column =
    case column of
        Completed completedColumn ->
            CompletedColumn.tagsToHide completedColumn

        Dated datedColumn ->
            DatedColumn.tagsToHide datedColumn

        NamedTag namedTagColumn ->
            NamedTagColumn.tagsToHide namedTagColumn

        OtherTags otherTagsColumn ->
            OtherTagsColumn.tagsToHide otherTagsColumn

        TodoSeq todoSeqColumn ->
            TodoSeqColumn.tagsToHide todoSeqColumn

        Undated undatedColumn ->
            UndatedColumn.tagsToHide undatedColumn

        Untagged untaggedColumn ->
            UntaggedColumn.tagsToHide untaggedColumn


toList : Column -> List TaskItem
toList column =
    case column of
        Completed completedColumn ->
            CompletedColumn.toList completedColumn

        Dated datedColumn ->
            DatedColumn.toList datedColumn

        NamedTag namedTagColumn ->
            NamedTagColumn.toList namedTagColumn

        OtherTags otherTagsColumn ->
            OtherTagsColumn.toList otherTagsColumn

        TodoSeq todoSeqColumn ->
            TodoSeqColumn.toList todoSeqColumn

        Undated undatedColumn ->
            UndatedColumn.toList undatedColumn

        Untagged untaggedColumn ->
            UntaggedColumn.toList untaggedColumn
