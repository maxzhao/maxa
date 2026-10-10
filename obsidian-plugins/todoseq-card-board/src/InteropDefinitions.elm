module InteropDefinitions exposing
    ( Flags
    , FromElm(..)
    , ToElm(..)
    , interop
    )

import DataviewTaskCompletion exposing (DataviewTaskCompletion)
import DecodeHelpers
import DragAndDrop.Coords as Coords exposing (Coords)
import DragAndDrop.DragData as DragData exposing (DragData)
import Filter exposing (Filter)
import Settings exposing (Settings)
import TaskItem exposing (TaskItem, TaskItemFields)
import TaskList exposing (TaskList)
import TextDirection exposing (TextDirection)
import TsJson.Decode as TsDecode
import TsJson.Encode as TsEncode exposing (required)


type FromElm
    = AddFilePreviewHovers (List { filePath : String, id : String })
    | CloseView
    | DeleteTask TaskItemFields
    | DisplayTaskMarkdown (List { filePath : String, taskMarkdown : List { id : String, markdown : String } })
    | ElmInitialized String
    | OpenTaskSourceFile TaskItemFields
    | OpenTodoSeqTaskEditor { taskId : String }
    | RequestFilterCandidates
    | ShowCardContextMenu { clientPos : ( Float, Float ), cardId : String }
    | ShowTodoSeqStateMenu { clientPos : ( Float, Float ), taskId : String }
    | TodoSeqCycleTaskState { taskId : String }
    | TodoSeqMoveTaskToColumn { taskId : String, columnId : String, defaultKeyword : Maybe String }
    | TodoSeqToggleTaskState { taskId : String, checked : Bool }
    | TrackDraggable { dragType : String, clientPos : Coords, draggableId : String }
    | UpdateSettings Settings
    | UpdateTasks { filePath : String, tasks : List { lineNumber : Int, originalLine : String, newText : String } }


type ToElm
    = ActiveStateUpdated Bool
    | ConfigChanged TextDirection
    | EditCardDueDate String
    | ElementDragged DragData
    | FilterCandidates (List Filter)
    | SettingsUpdated Settings
    | ShowBoard Int
    | TaskItemsAdded TaskList
    | TaskItemsDeleted (List String)
    | TaskItemsDeletedAndAdded ( List String, List TaskItem )
    | TaskItemsRefreshed TaskList
    | TaskItemsUpdated (List ( String, TaskItem ))


type alias Flags =
    { dataviewTaskCompletion : DataviewTaskCompletion
    , firstDayOfWeek : Int
    , now : Int
    , rightToLeft : Bool
    , settings : Settings
    , uniqueId : String
    , zone : Int
    }


interop : { toElm : TsDecode.Decoder ToElm, fromElm : TsEncode.Encoder FromElm, flags : TsDecode.Decoder Flags }
interop =
    { toElm = toElm
    , fromElm = fromElm
    , flags = flags
    }



-- INTEROP


flags : TsDecode.Decoder Flags
flags =
    TsDecode.succeed Flags
        |> TsDecode.andMap (TsDecode.field "dataviewTaskCompletion" DataviewTaskCompletion.decoder)
        |> TsDecode.andMap (TsDecode.field "firstDayOfWeek" TsDecode.int)
        |> TsDecode.andMap (TsDecode.field "now" TsDecode.int)
        |> TsDecode.andMap (TsDecode.field "rightToLeft" TsDecode.bool)
        |> TsDecode.andMap (TsDecode.field "settings" Settings.decoder)
        |> TsDecode.andMap (TsDecode.field "uniqueId" TsDecode.string)
        |> TsDecode.andMap (TsDecode.field "zone" TsDecode.int)


toElm : TsDecode.Decoder ToElm
toElm =
    TsDecode.oneOf
        [ DecodeHelpers.toElmVariant "activeStateUpdated" ActiveStateUpdated TsDecode.bool
        , DecodeHelpers.toElmVariant "configChanged" ConfigChanged configChangedDecoder
        , DecodeHelpers.toElmVariant "editCardDueDate" EditCardDueDate TsDecode.string
        , DecodeHelpers.toElmVariant "elementDragged" ElementDragged DragData.decoder
        , DecodeHelpers.toElmVariant "filterCandidates" FilterCandidates (TsDecode.list Filter.decoder)
        , DecodeHelpers.toElmVariant "settingsUpdated" SettingsUpdated Settings.decoder
        , DecodeHelpers.toElmVariant "showBoard" ShowBoard TsDecode.int
        , DecodeHelpers.toElmVariant "taskItemsAdded" TaskItemsAdded TaskList.decoder
        , DecodeHelpers.toElmVariant "taskItemsDeleted" TaskItemsDeleted (TsDecode.list TsDecode.string)
        , DecodeHelpers.toElmVariant "taskItemsDeletedAndAdded" TaskItemsDeletedAndAdded deleteAndAddDecoder
        , DecodeHelpers.toElmVariant "taskItemsRefreshed" TaskItemsRefreshed TaskList.decoder
        , DecodeHelpers.toElmVariant "taskItemsUpdated" TaskItemsUpdated updateDetailsDecoder
        ]


fromElm : TsEncode.Encoder FromElm
fromElm =
    TsEncode.union
        (\vAddFilePreviewHovers vCloseView vDeleteTask vDisplayTaskMarkdown vElmInitialized vOpenTaskSourceFile vOpenTodoSeqTaskEditor vRequestPaths vShowCardContextMenu vShowTodoSeqStateMenu vTodoSeqCycleTaskState vTodoSeqMoveTaskToColumn vTodoSeqToggleTaskState vTrackDraggable vUpdateSettings vUpdateTasks value ->
            case value of
                AddFilePreviewHovers info ->
                    vAddFilePreviewHovers info

                CloseView ->
                    vCloseView

                DeleteTask taskItemFields ->
                    vDeleteTask taskItemFields

                DisplayTaskMarkdown info ->
                    vDisplayTaskMarkdown info

                ElmInitialized uniqueId ->
                    vElmInitialized uniqueId

                OpenTaskSourceFile taskItemFields ->
                    vOpenTaskSourceFile taskItemFields

                OpenTodoSeqTaskEditor info ->
                    vOpenTodoSeqTaskEditor info

                RequestFilterCandidates ->
                    vRequestPaths

                ShowCardContextMenu info ->
                    vShowCardContextMenu info

                ShowTodoSeqStateMenu info ->
                    vShowTodoSeqStateMenu info

                TodoSeqCycleTaskState info ->
                    vTodoSeqCycleTaskState info

                TodoSeqMoveTaskToColumn info ->
                    vTodoSeqMoveTaskToColumn info

                TodoSeqToggleTaskState info ->
                    vTodoSeqToggleTaskState info

                TrackDraggable info ->
                    vTrackDraggable info

                UpdateSettings settings ->
                    vUpdateSettings settings

                UpdateTasks info ->
                    vUpdateTasks info
        )
        |> TsEncode.variantTagged "addFilePreviewHovers" addFilePreviewHoversEncoder
        |> TsEncode.variant0 "closeView"
        |> TsEncode.variantTagged "deleteTask" deleteTaskEncoder
        |> TsEncode.variantTagged "displayTaskMarkdown" displayTaskMarkdownEncoder
        |> TsEncode.variantTagged "elmInitialized" TsEncode.string
        |> TsEncode.variantTagged "openTaskSourceFile" openTaskSourceFileEncoder
        |> TsEncode.variantTagged "openTodoSeqTaskEditor" openTodoSeqTaskEditorEncoder
        |> TsEncode.variant0 "requestFilterCandidates"
        |> TsEncode.variantTagged "showCardContextMenu" showCardContextMenuEncoder
        |> TsEncode.variantTagged "showTodoSeqStateMenu" showTodoSeqStateMenuEncoder
        |> TsEncode.variantTagged "todoSeqCycleTaskState" todoSeqCycleTaskStateEncoder
        |> TsEncode.variantTagged "todoSeqMoveTaskToColumn" todoSeqMoveTaskToColumnEncoder
        |> TsEncode.variantTagged "todoSeqToggleTaskState" todoSeqToggleTaskStateEncoder
        |> TsEncode.variantTagged "trackDraggable" trackDraggableEncoder
        |> TsEncode.variantTagged "updateSettings" Settings.encoder
        |> TsEncode.variantTagged "updateTasks" updateTasksEncoder
        |> TsEncode.buildUnion



-- HELPERS


addFilePreviewHoversEncoder : TsEncode.Encoder (List { filePath : String, id : String })
addFilePreviewHoversEncoder =
    TsEncode.list
        (TsEncode.object
            [ required "filePath" .filePath TsEncode.string
            , required "id" .id TsEncode.string
            ]
        )


configChangedDecoder : TsDecode.Decoder TextDirection
configChangedDecoder =
    TsDecode.succeed TextDirection.fromRtlFlag
        |> TsDecode.andMap (TsDecode.field "rightToLeft" TsDecode.bool)


deleteAndAddDecoder : TsDecode.Decoder ( List String, List TaskItem )
deleteAndAddDecoder =
    TsDecode.tuple (TsDecode.list TsDecode.string) (TsDecode.list TaskItem.decoder)


deleteTaskEncoder : TsEncode.Encoder { a | filePath : String, lineNumber : Int, originalLine : String }
deleteTaskEncoder =
    TsEncode.object
        [ required "filePath" .filePath TsEncode.string
        , required "lineNumber" .lineNumber TsEncode.int
        , required "originalLine" .originalLine TsEncode.string
        ]


displayTaskMarkdownEncoder : TsEncode.Encoder (List { filePath : String, taskMarkdown : List { id : String, markdown : String } })
displayTaskMarkdownEncoder =
    TsEncode.list
        (TsEncode.object
            [ required "filePath" .filePath TsEncode.string
            , required "taskMarkdown" .taskMarkdown (TsEncode.list markdownListEncoder)
            ]
        )


markdownListEncoder : TsEncode.Encoder { id : String, markdown : String }
markdownListEncoder =
    TsEncode.object
        [ required "id" .id TsEncode.string
        , required "markdown" .markdown TsEncode.string
        ]


openTaskSourceFileEncoder : TsEncode.Encoder { a | filePath : String, lineNumber : Int, originalLine : String }
openTaskSourceFileEncoder =
    TsEncode.object
        [ required "filePath" .filePath TsEncode.string
        , required "lineNumber" .lineNumber TsEncode.int
        , required "originalLine" .originalLine TsEncode.string
        ]


openTodoSeqTaskEditorEncoder : TsEncode.Encoder { a | taskId : String }
openTodoSeqTaskEditorEncoder =
    TsEncode.object
        [ required "taskId" .taskId TsEncode.string
        ]


showCardContextMenuEncoder : TsEncode.Encoder { a | clientPos : ( Float, Float ), cardId : String }
showCardContextMenuEncoder =
    TsEncode.object
        [ required "clientPos" .clientPos (TsEncode.tuple TsEncode.float TsEncode.float)
        , required "cardId" .cardId TsEncode.string
        ]


showTodoSeqStateMenuEncoder : TsEncode.Encoder { a | clientPos : ( Float, Float ), taskId : String }
showTodoSeqStateMenuEncoder =
    TsEncode.object
        [ required "clientPos" .clientPos (TsEncode.tuple TsEncode.float TsEncode.float)
        , required "taskId" .taskId TsEncode.string
        ]


todoSeqCycleTaskStateEncoder : TsEncode.Encoder { a | taskId : String }
todoSeqCycleTaskStateEncoder =
    TsEncode.object
        [ required "taskId" .taskId TsEncode.string
        ]


todoSeqMoveTaskToColumnEncoder : TsEncode.Encoder { a | taskId : String, columnId : String, defaultKeyword : Maybe String }
todoSeqMoveTaskToColumnEncoder =
    TsEncode.object
        [ required "taskId" .taskId TsEncode.string
        , required "columnId" .columnId TsEncode.string
        , required "defaultKeyword" .defaultKeyword (TsEncode.maybe TsEncode.string)
        ]


todoSeqToggleTaskStateEncoder : TsEncode.Encoder { a | taskId : String, checked : Bool }
todoSeqToggleTaskStateEncoder =
    TsEncode.object
        [ required "taskId" .taskId TsEncode.string
        , required "checked" .checked TsEncode.bool
        ]


taskUpdatesEncoder : TsEncode.Encoder { lineNumber : Int, originalLine : String, newText : String }
taskUpdatesEncoder =
    TsEncode.object
        [ required "lineNumber" .lineNumber TsEncode.int
        , required "originalLine" .originalLine TsEncode.string
        , required "newText" .newText TsEncode.string
        ]


updateDetailsDecoder : TsDecode.Decoder (List ( String, TaskItem ))
updateDetailsDecoder =
    TsDecode.list <| TsDecode.tuple TsDecode.string TaskItem.decoder


trackDraggableEncoder : TsEncode.Encoder { dragType : String, clientPos : Coords, draggableId : String }
trackDraggableEncoder =
    TsEncode.object
        [ required "dragType" .dragType TsEncode.string
        , required "clientPos" .clientPos Coords.encoder
        , required "draggableId" .draggableId TsEncode.string
        ]


updateTasksEncoder : TsEncode.Encoder { filePath : String, tasks : List { lineNumber : Int, originalLine : String, newText : String } }
updateTasksEncoder =
    TsEncode.object
        [ required "filePath" .filePath TsEncode.string
        , required "tasks" .tasks (TsEncode.list taskUpdatesEncoder)
        ]
