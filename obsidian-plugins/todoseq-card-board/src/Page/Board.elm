module Page.Board exposing
    ( Model
    , Msg(..)
    , init
    , mapSession
    , toSession
    , update
    , view
    )

import Board exposing (Board)
import BoardConfig exposing (BoardConfig)
import Boards exposing (Boards)
import Card exposing (Card)
import Column exposing (Column)
import Columns
import Date exposing (Date)
import DragAndDrop.BeaconPosition as BeaconPosition exposing (BeaconPosition)
import DragAndDrop.Coords as Coords
import DragAndDrop.DragData as DragData exposing (DragData)
import DragAndDrop.DragTracker as DragTracker exposing (DragTracker)
import DragAndDrop.Rect as Rect
import FeatherIcons
import Html exposing (Attribute, Html)
import Html.Attributes exposing (attribute, checked, class, disabled, hidden, id, style, tabindex, title, type_)
import Html.Events exposing (onCheck, onClick)
import Html.Events.Extra.Mouse as Mouse exposing (onContextMenu, onDown)
import Html.Keyed
import Html.Lazy
import InteropPorts
import Json.Decode as JD
import Json.Encode as JE
import List.Extra as LE
import Page.Helper.DatePicker as DatePicker exposing (DatePicker)
import SafeZipper
import Session exposing (Session, TaskCompletionSettings)
import Set exposing (Set)
import TagList
import TaskItem exposing (TaskItem, TaskItemFields)
import TaskList
import TextDirection
import Time
import TimeWithZone exposing (TimeWithZone)
import UpdatedTaskItem exposing (UpdatedTaskItem)



-- MODEL


type Model
    = DeletingCard String String ViewState Session
    | EditingCardDueDate DatePicker TaskItem ViewState Session
    | ViewingBoard ViewState Session


type alias ViewState =
    { expandedSubtaskCards : Set String
    }


init : Session -> Model
init session =
    ViewingBoard initViewState session


initViewState : ViewState
initViewState =
    { expandedSubtaskCards = Set.empty
    }


cancelCurrentState : Model -> Model
cancelCurrentState model =
    ViewingBoard (viewState model) (toSession model)


deleteCardRequested : String -> String -> Model -> Model
deleteCardRequested title cardId model =
    DeletingCard title cardId (viewState model) (toSession model)


deleteCardConfirmed : Model -> Model
deleteCardConfirmed model =
    ViewingBoard (viewState model) (toSession model)


editCardDueDateConfirmed : Model -> Model
editCardDueDateConfirmed model =
    ViewingBoard (viewState model) (toSession model)


editCardDueDateRequested : String -> Model -> Model
editCardDueDateRequested cardId model =
    let
        taskItem : Maybe TaskItem
        taskItem =
            toSession model
                |> Session.findCard cardId
                |> Maybe.map Card.taskItem
    in
    case taskItem of
        Just taskToEdit ->
            let
                date : Maybe Date
                date =
                    TaskItem.due taskToEdit

                today : Date
                today =
                    toSession model
                        |> Session.timeWithZone
                        |> TimeWithZone.toDate

                firstDayOfWeek : Time.Weekday
                firstDayOfWeek =
                    toSession model
                        |> Session.firstDayOfWeek
            in
            EditingCardDueDate (DatePicker.init firstDayOfWeek today date) taskToEdit (viewState model) (toSession model)

        Nothing ->
            model


mapSession : (Session -> Session) -> Model -> Model
mapSession fn model =
    case model of
        ViewingBoard state session ->
            ViewingBoard state <| fn session

        DeletingCard title cardId state session ->
            DeletingCard title cardId state <| fn session

        EditingCardDueDate datePicker card state session ->
            EditingCardDueDate datePicker card state <| fn session


toSession : Model -> Session
toSession model =
    case model of
        ViewingBoard _ session ->
            session

        DeletingCard _ _ _ session ->
            session

        EditingCardDueDate _ _ _ session ->
            session


viewState : Model -> ViewState
viewState model =
    case model of
        ViewingBoard state _ ->
            state

        DeletingCard _ _ state _ ->
            state

        EditingCardDueDate _ _ state _ ->
            state


mapViewState : (ViewState -> ViewState) -> Model -> Model
mapViewState fn model =
    case model of
        ViewingBoard state session ->
            ViewingBoard (fn state) session

        DeletingCard title cardId state session ->
            DeletingCard title cardId (fn state) session

        EditingCardDueDate datePicker card state session ->
            EditingCardDueDate datePicker card (fn state) session



-- UPDATE


type Msg
    = CardMouseDown
    | CardRightMouseDown String Mouse.Event
    | CardStatusButtonClicked String
    | CardTouchStart ( String, DragTracker.ClientData )
    | ColumnMouseDown ( String, DragTracker.ClientData )
    | DatePickerMsg DatePicker.Msg
    | DeleteConfirmed String
    | EditCardDueDateConfirmed
    | EditCardDueDateRequested String
    | ElementDragged DragData
    | ModalCancelClicked
    | ModalCloseClicked
    | SettingsClicked
    | TabHeaderMouseDown ( String, DragTracker.ClientData )
    | TabSelected Int
    | TaskItemEditClicked String
    | TaskItemDeleteClicked String String
    | TaskItemToggled String
    | TodoSeqKeywordClicked String
    | TodoSeqStateMenuRequested String Mouse.Event
    | TodoSeqTaskMovedToColumn String String (Maybe String)
    | TodoSeqTaskToggled String Bool
    | ToggleCardSubtasks String
    | ToggleColumnCollapse Int Bool


tagHeaderDragType : String
tagHeaderDragType =
    "todoseq-card-board-tag-header"


columnDragType : String
columnDragType =
    "todoseq-card-board-column"


cardDragType : String
cardDragType =
    "todoseq-card-board-card"


update : Msg -> Model -> ( Model, Cmd Msg, Session.Msg )
update msg model =
    case msg of
        CardMouseDown ->
            ( model, Cmd.none, Session.NoOp )

        CardRightMouseDown cardId event ->
            ( model
            , InteropPorts.showCardContextMenu event.clientPos cardId
            , Session.NoOp
            )

        CardStatusButtonClicked cardId ->
            ( model
            , InteropPorts.showCardContextMenu ( 0, 0 ) cardId
            , Session.NoOp
            )


        CardTouchStart ( domId, clientData ) ->
            ( mapSession (Session.waitForDrag clientData) model
            , InteropPorts.trackDraggable cardDragType clientData.clientPos domId
            , Session.NoOp
            )

        ColumnMouseDown ( domId, clientData ) ->
            ( mapSession (Session.waitForDrag clientData) model
            , InteropPorts.trackDraggable columnDragType clientData.clientPos domId
            , Session.NoOp
            )

        DatePickerMsg subMsg ->
            case model of
                EditingCardDueDate datePicker card state session ->
                    let
                        newPicker : DatePicker
                        newPicker =
                            DatePicker.update subMsg datePicker
                    in
                    ( EditingCardDueDate newPicker card state session
                    , Cmd.none
                    , Session.NoOp
                    )

                _ ->
                    ( model, Cmd.none, Session.NoOp )

        DeleteConfirmed cardId ->
            ( deleteCardConfirmed model
            , cmdIfHasTask cardId model InteropPorts.deleteTask
            , Session.NoOp
            )

        EditCardDueDateConfirmed ->
            case model of
                EditingCardDueDate datePicker taskItem _ session ->
                    let
                        cmd : Cmd Msg
                        cmd =
                            InteropPorts.rewriteTasks
                                (TaskItem.filePath taskItem)
                                updatedTaskItems

                        taskCompletionSettings : TaskCompletionSettings
                        taskCompletionSettings =
                            Session.taskCompletionSettings session

                        updatedTaskItems : List UpdatedTaskItem
                        updatedTaskItems =
                            taskItem
                                |> UpdatedTaskItem.init
                                |> UpdatedTaskItem.updateDate taskCompletionSettings (DatePicker.pickedDate datePicker)
                                |> List.singleton
                    in
                    ( editCardDueDateConfirmed model
                    , cmd
                    , Session.NoOp
                    )

                _ ->
                    ( model, Cmd.none, Session.NoOp )

        EditCardDueDateRequested cardId ->
            ( editCardDueDateRequested cardId model
            , Cmd.none
            , Session.NoOp
            )

        ElementDragged dragData ->
            case dragData.dragAction of
                DragData.Move ->
                    if dragData.dragType == tagHeaderDragType then
                        ( model
                            |> updateBoardOrder (Session.dragTracker <| toSession model) dragData
                            |> (mapSession <| Session.moveDragable dragData)
                        , Cmd.none
                        , Session.NoOp
                        )

                    else if dragData.dragType == columnDragType then
                        ( model
                            |> updateColumnOrder (Session.dragTracker <| toSession model) dragData
                            |> (mapSession <| Session.moveDragable dragData)
                        , displayGhostMarkdown model
                        , Session.NoOp
                        )

                    else if dragData.dragType == cardDragType then
                        ( model
                            |> (mapSession <| Session.moveDragable dragData)
                        , Cmd.none
                        , Session.NoOp
                        )

                    else
                        ( model, Cmd.none, Session.NoOp )

                DragData.Stop ->
                    let
                        dragTracker : DragTracker
                        dragTracker =
                            Session.dragTracker <| toSession model

                        moveCmd : Cmd Msg
                        moveCmd =
                            if DragTracker.dragType dragTracker == Just cardDragType then
                                Cmd.none

                            else
                                InteropPorts.updateSettings <| Session.settings <| toSession model
                    in
                    ( mapSession Session.stopTrackingDragable model
                    , moveCmd
                    , Session.NoOp
                    )

        ModalCancelClicked ->
            ( cancelCurrentState model
            , Cmd.none
            , Session.NoOp
            )

        ModalCloseClicked ->
            ( cancelCurrentState model
            , Cmd.none
            , Session.NoOp
            )

        SettingsClicked ->
            ( model
            , Cmd.none
            , Session.SettingsClicked
            )

        TabHeaderMouseDown ( domId, clientData ) ->
            ( mapSession (Session.waitForDrag clientData) model
            , InteropPorts.trackDraggable tagHeaderDragType clientData.clientPos domId
            , Session.NoOp
            )

        TabSelected tabIndex ->
            ( mapSession (Session.switchToBoardAt tabIndex) model
            , Cmd.none
            , Session.NoOp
            )

        TaskItemDeleteClicked title id ->
            ( deleteCardRequested title id model
            , Cmd.none
            , Session.NoOp
            )

        TaskItemEditClicked id ->
            ( model
            , InteropPorts.openTodoSeqTaskEditor id
            , Session.NoOp
            )

        TaskItemToggled id ->
            let
                cmd : Cmd Msg
                cmd =
                    session
                        |> Session.taskContainingId id
                        |> Maybe.map toggleCmd
                        |> Maybe.withDefault Cmd.none

                updatedTaskItems : TaskItem -> List UpdatedTaskItem
                updatedTaskItems taskItem =
                    taskItem
                        |> TaskItem.tasksToToggle id timeWithZone
                        |> List.map UpdatedTaskItem.init
                        |> List.map (UpdatedTaskItem.toggleCompletion taskCompletionSettings timeWithZone)

                session : Session
                session =
                    toSession model

                taskCompletionSettings : TaskCompletionSettings
                taskCompletionSettings =
                    Session.taskCompletionSettings session

                timeWithZone : TimeWithZone
                timeWithZone =
                    Session.timeWithZone session

                toggleCmd : TaskItem -> Cmd Msg
                toggleCmd taskItem =
                    InteropPorts.rewriteTasks
                        (TaskItem.filePath taskItem)
                        (updatedTaskItems taskItem)
            in
            ( model
            , cmd
            , Session.NoOp
            )

        TodoSeqKeywordClicked taskId ->
            ( model
            , InteropPorts.todoSeqCycleTaskState taskId
            , Session.NoOp
            )

        TodoSeqStateMenuRequested taskId event ->
            ( model
            , InteropPorts.showTodoSeqStateMenu event.clientPos taskId
            , Session.NoOp
            )

        TodoSeqTaskMovedToColumn taskId columnId defaultKeyword ->
            ( model
            , InteropPorts.todoSeqMoveTaskToColumn taskId columnId defaultKeyword
            , Session.NoOp
            )

        TodoSeqTaskToggled taskId checked ->
            ( model
            , InteropPorts.todoSeqToggleTaskState taskId checked
            , Session.NoOp
            )

        ToggleCardSubtasks cardId ->
            let
                toggleExpandedSubtasks : ViewState -> ViewState
                toggleExpandedSubtasks state =
                    { state
                        | expandedSubtaskCards =
                            if Set.member cardId state.expandedSubtaskCards then
                                Set.remove cardId state.expandedSubtaskCards

                            else
                                Set.insert cardId state.expandedSubtaskCards
                    }

                cardToRedraw : List Card
                cardToRedraw =
                    model
                        |> toSession
                        |> Session.cards
                        |> List.filter (\card -> Card.id card == cardId)
            in
            ( mapViewState toggleExpandedSubtasks model
            , InteropPorts.displayTaskMarkdown cardToRedraw
            , Session.NoOp
            )

        ToggleColumnCollapse columnIndex newState ->
            let
                newSession : Session
                newSession =
                    Session.updateColumnCollapse columnIndex newState (toSession model)
            in
            ( mapSession (always newSession) model
            , InteropPorts.updateSettings <| Session.settings newSession
            , Session.NoOp
            )



-- VIEW


view : Model -> Html Msg
view model =
    case model of
        ViewingBoard state session ->
            Html.div [ class "todoseq-card-board-page" ]
                [ boardsView state session ]

        DeletingCard title cardId state session ->
            Html.div [ class "todoseq-card-board-page" ]
                [ boardsView state session
                , modalDeleteCardConfirm title cardId
                ]

        EditingCardDueDate datePicker taskItem state session ->
            Html.div [ class "todoseq-card-board-page" ]
                [ boardsView state session
                , modalEditCardDueDate datePicker taskItem session
                ]


modalEditCardDueDate : DatePicker -> TaskItem -> Session -> Html Msg
modalEditCardDueDate datePicker taskItem session =
    let
        containingColumns : List String
        containingColumns =
            case currentBoardConfig of
                Just boardConfig ->
                    Board.init "" boardConfig TaskList.empty
                        |> Board.columns ignoreFileNameDates today
                        |> Columns.fromList
                        |> Columns.addTaskItem today updatedTaskItem
                        |> Columns.toList
                        |> List.filter (\c -> Column.cardCount c /= 0)
                        |> List.map Column.name

                Nothing ->
                    []

        currentBoardConfig : Maybe BoardConfig
        currentBoardConfig =
            Session.boardConfigs session
                |> SafeZipper.current

        ignoreFileNameDates : Bool
        ignoreFileNameDates =
            Session.ignoreFileNameDates session

        isInvalid : Bool
        isInvalid =
            not <| DatePicker.isValid datePicker

        today : Date
        today =
            Session.timeWithZone session
                |> TimeWithZone.toDate

        updatedTaskItem : TaskItem
        updatedTaskItem =
            if isInvalid then
                taskItem

            else
                TaskItem.updateDueDate (DatePicker.pickedDate datePicker) taskItem
    in
    Html.div [ class "modal-container" ]
        [ Html.div
            [ class "modal-bg"
            , style "opacity" "0.85"
            ]
            []
        , Html.div
            [ class "modal"
            , class "edit-date"
            ]
            [ Html.div
                [ class "modal-close-button"
                , onClick ModalCloseClicked
                ]
                []
            , Html.div [ class "modal-title" ]
                []
            , Html.div [ class "modal-content" ]
                [ Html.div [ class "setting-item setting-item-heading" ]
                    [ Html.div [ class "setting-item-info" ]
                        [ Html.div [ class "setting-item-name" ]
                            [ Html.text <| "Task: " ++ TaskItem.title taskItem ]
                        , Html.div [ class "setting-item-description" ]
                            []
                        ]
                    , Html.div [ class "setting-item-control" ] []
                    ]
                , Html.div [ class "setting-item" ]
                    [ Html.div [ class "setting-item-info" ]
                        [ Html.div [ class "setting-item-name" ]
                            [ Html.text "Due date" ]
                        , Html.div [ class "setting-item-description" ]
                            [ Html.text "Leave blank to clear the due date." ]
                        ]
                    , Html.div [ class "setting-item-control" ]
                        [ DatePicker.view datePicker
                            |> Html.map DatePickerMsg
                        ]
                    ]
                , Html.div [ class "setting-item" ]
                    [ Html.div [ class "setting-item-info" ]
                        [ Html.div [ class "setting-item-name" ]
                            [ Html.text "Containing columns" ]
                        , containingColumnsText containingColumns
                        ]
                    , containingColumnsList containingColumns
                    ]
                ]
            , Html.div [ class "modal-button-container" ]
                [ Html.button
                    [ attributeIf (not isInvalid) (class "mod-cta")
                    , attributeIf isInvalid (attribute "aria-disabled" "true")
                    , onClick EditCardDueDateConfirmed
                    , disabled isInvalid
                    , tabindex 2
                    ]
                    [ Html.text "Save"
                    ]
                , Html.button
                    [ onClick ModalCancelClicked
                    , tabindex 3
                    ]
                    [ Html.text "Cancel"
                    ]
                ]
            ]
        ]


containingColumnsText : List String -> Html Msg
containingColumnsText containingColumns =
    if List.length containingColumns == 0 then
        Html.div
            [ class "setting-item-description"
            , class "mod-warning"
            ]
            [ Html.text "If you save with this due date, this task will no longer appear on this board." ]

    else
        Html.div [ class "setting-item-description" ]
            [ Html.text "If you save with this due date, this task will appear in the following columns on this board." ]


containingColumnsList : List String -> Html Msg
containingColumnsList containingColumns =
    if List.length containingColumns == 0 then
        Html.text ""

    else
        Html.div
            [ class "multiSelect-items"
            , class "mod-faux"
            ]
            (List.map columnNamePill containingColumns)


columnNamePill : String -> Html Msg
columnNamePill name =
    Html.div [ class "multiSelect-item" ]
        [ Html.span [ class "multiSelect-item-single" ]
            [ Html.text name ]
        ]


modalDeleteCardConfirm : String -> String -> Html Msg
modalDeleteCardConfirm title cardId =
    Html.div [ class "modal-container" ]
        [ Html.div
            [ class "modal-bg"
            , style "opacity" "0.85"
            ]
            []
        , Html.div [ class "modal" ]
            [ Html.div
                [ class "modal-close-button"
                , onClick ModalCloseClicked
                ]
                []
            , Html.div [ class "modal-title" ]
                [ Html.text "Delete Card" ]
            , Html.div [ class "modal-content" ]
                [ Html.p [ class "mod-warning" ]
                    [ Html.text <|
                        "Press Delete to confirm you wish to delete the \""
                            ++ title
                            ++ "\" card.  This does not delete the task from your "
                            ++ "markdown, it encloses it in <del> tags."
                    ]
                ]
            , Html.div [ class "modal-button-container" ]
                [ Html.button
                    [ class "mod-warning"
                    , onClick <| DeleteConfirmed cardId
                    , tabindex 1
                    ]
                    [ Html.text "Delete"
                    ]
                , Html.button
                    [ onClick <| ModalCancelClicked
                    , tabindex 2
                    ]
                    [ Html.text "Cancel"
                    ]
                ]
            ]
        ]


boardsView : ViewState -> Session -> Html Msg
boardsView state session =
    if SafeZipper.length (Session.boardConfigs session) == 0 then
        Html.text "Loading tasks...."

    else
        let
            boards : Boards
            boards =
                Boards.init (Session.uniqueId session) (Session.boardConfigs session) (Session.taskList session)

            currentBoardIndex : Maybe Int
            currentBoardIndex =
                Boards.currentIndex boards

            ignoreFileNameDates : Bool
            ignoreFileNameDates =
                Session.ignoreFileNameDates session

            today : Date
            today =
                Session.timeWithZone session
                    |> TimeWithZone.toDate

            isDragging : Bool
            isDragging =
                Session.isDragging session && draggedType == Just tagHeaderDragType

            dragTracker : DragTracker
            dragTracker =
                session
                    |> Session.dragTracker

            draggedType : Maybe String
            draggedType =
                DragTracker.dragType dragTracker
        in
        Html.div
            [ class "todoseq-card-board-board-frame"
            , attribute "dir" (TextDirection.toString <| Session.textDirection session)
            , attributeIf isDragging (style "cursor" "grabbing")
            ]
            [ Html.div [ class "workspace-tab-header-container" ]
                [ Html.div
                    [ class "sidebar-toggle-button"
                    , class "mod-left"
                    , attribute "aria-label" "Settings"
                    , attribute "aria-label-position" "right"
                    ]
                    [ Html.div
                        [ class "clickable-icon"
                        , onClick SettingsClicked
                        ]
                        [ FeatherIcons.settings
                            |> FeatherIcons.withSize 1
                            |> FeatherIcons.withSizeUnit "em"
                            |> FeatherIcons.toHtml []
                        ]
                    ]
                , Html.div
                    [ class "workspace-tab-header-container-inner" ]
                    (tabHeaders isDragging currentBoardIndex boards
                        ++ [ viewDraggedHeader isDragging session ]
                    )
                , Html.div
                    [ class "todoseq-card-board-tab-header-spacer" ]
                    []
                ]
            , Html.Keyed.node "div"
                [ class "todoseq-card-board-boards"
                , class "todoseq-card-board-column-container"
                ]
                (Boards.boardZipper boards
                    |> SafeZipper.mapSelectedAndRest
                        (keyedSelectedBoardView state ignoreFileNameDates today dragTracker)
                        (keyedBoardView state ignoreFileNameDates today)
                    |> SafeZipper.toList
                )
            ]


tabHeaders : Bool -> Maybe Int -> Boards -> List (Html Msg)
tabHeaders isDragging currentBoardIndex boards =
    Boards.names boards
        |> SafeZipper.indexedMapSelectedAndRest (selectedTabHeader isDragging) (tabHeader isDragging currentBoardIndex)
        |> SafeZipper.toList


tabHeader : Bool -> Maybe Int -> Int -> String -> Html Msg
tabHeader isDragging currentBoardIndex tabIndex name =
    let
        headerClass : String
        headerClass =
            tabHeaderClass currentBoardIndex tabIndex

        domId : String
        domId =
            "todoseq-card-board-tab:" ++ String.fromInt tabIndex
    in
    Html.div
        [ id domId
        , class ("workspace-tab-header" ++ headerClass)
        , attributeIf (not isDragging) (attribute "aria-label" name)
        , attributeIf (not isDragging) (attribute "aria-label-delay" "50")
        , onClick <| TabSelected tabIndex
        , onDown
            (\e ->
                TabHeaderMouseDown <|
                    ( domId
                    , { uniqueId = name
                      , clientPos = Coords.fromFloatTuple e.clientPos
                      , offsetPos = Coords.fromFloatTuple e.offsetPos
                      }
                    )
            )
        ]
        [ beacon tagHeaderBeaconType (BeaconPosition.Before name)
        , Html.div
            [ class "workspace-tab-header-inner" ]
            [ Html.div [ class "workspace-tab-header-inner-title" ]
                [ Html.text <| name ]
            ]
        , beacon tagHeaderBeaconType (BeaconPosition.After name)
        ]


selectedTabHeader : Bool -> Int -> String -> Html Msg
selectedTabHeader isDragging tabIndex name =
    let
        domId : String
        domId =
            "todoseq-card-board-tab:" ++ String.fromInt tabIndex
    in
    Html.div
        [ class "workspace-tab-header is-active"
        , id domId
        , attributeIf (not isDragging) (attribute "aria-label" name)
        , attributeIf isDragging (attribute "aria-label" "")
        , attributeIf (not isDragging) (attribute "aria-label-delay" "50")
        , attributeIf isDragging (style "opacity" "0.0")
        , onDown
            (\e ->
                TabHeaderMouseDown <|
                    ( domId
                    , { uniqueId = name
                      , clientPos = Coords.fromFloatTuple e.clientPos
                      , offsetPos = Coords.fromFloatTuple e.offsetPos
                      }
                    )
            )
        ]
        [ beacon tagHeaderBeaconType (BeaconPosition.Before name)
        , Html.div
            [ class "workspace-tab-header-inner" ]
            [ Html.div [ class "workspace-tab-header-inner-title" ]
                [ Html.text <| name ]
            ]
        , beacon tagHeaderBeaconType (BeaconPosition.After name)
        ]


viewDraggedHeader : Bool -> Session -> Html Msg
viewDraggedHeader isDragging session =
    case ( isDragging, Session.dragTracker session ) of
        ( True, DragTracker.Dragging clientData domData ) ->
            Html.div
                [ class "workspace-tab-header is-active"
                , id <| "todoseq-card-board-tab:being-dragged"
                , style "position" "fixed"
                , style "top" (String.fromFloat (domData.draggedNodeStartRect.y - domData.offset.y) ++ "px")
                , style "left" (String.fromFloat (clientData.clientPos.x - domData.offset.x - clientData.offsetPos.x) ++ "px")
                , style "width" (String.fromFloat domData.draggedNodeStartRect.width ++ "px")
                , style "height" (String.fromFloat domData.draggedNodeStartRect.height ++ "px")
                , style "cursor" "grabbing"
                , style "opacity" "0.85"
                ]
                [ Html.div
                    [ class "workspace-tab-header-inner" ]
                    [ Html.div [ class "workspace-tab-header-inner-title" ]
                        [ Html.text <| clientData.uniqueId ]
                    ]
                ]

        _ ->
            empty


keyedBoardView : ViewState -> Bool -> Date -> Board -> ( String, Html Msg )
keyedBoardView state ignoreFileNameDates today board =
    ( Board.id board, Html.Lazy.lazy4 boardView state ignoreFileNameDates today board )


boardView : ViewState -> Bool -> Date -> Board -> Html Msg
boardView state ignoreFileNameDates today board =
    Html.div
        [ class "todoseq-card-board-board"
        , hidden True
        ]
        [ Html.Keyed.node "div"
            [ class "todoseq-card-board-columns" ]
            (board
                |> Board.columns ignoreFileNameDates today
                |> List.indexedMap (\index column -> keyedColumnView state Nothing (Board.id board) index today column)
            )
        ]


keyedSelectedBoardView : ViewState -> Bool -> Date -> DragTracker -> Board -> ( String, Html Msg )
keyedSelectedBoardView state ignoreFileNameDates today dragTracker board =
    ( Board.id board, Html.Lazy.lazy5 selectedBoardView state ignoreFileNameDates today dragTracker board )


selectedBoardView : ViewState -> Bool -> Date -> DragTracker -> Board -> Html Msg
selectedBoardView state ignoreFileNameDates today dragTracker board =
    let
        draggedColumn : Maybe Column
        draggedColumn =
            board
                |> Board.columns ignoreFileNameDates today
                |> LE.find (\c -> Just (Column.name c) == draggedUniqueId)

        draggedType : Maybe String
        draggedType =
            DragTracker.dragType dragTracker

        draggedUniqueId : Maybe String
        draggedUniqueId =
            if isDragging then
                DragTracker.uniqueId dragTracker

            else
                Nothing

        isDragging : Bool
        isDragging =
            DragTracker.isDragging dragTracker && draggedType == Just columnDragType
    in
    Html.div [ class "todoseq-card-board-board" ]
        [ Html.Keyed.node "div"
            [ class "todoseq-card-board-columns" ]
            ((board
                |> Board.columns ignoreFileNameDates today
                |> List.indexedMap (\index column -> keyedColumnView state draggedUniqueId (Board.id board) index today column)
             )
                |> (\cs ->
                        List.append cs
                            [ keyedColumnGhostView (Board.id board) today isDragging dragTracker draggedColumn ]
                   )
            )
        ]


keyedColumnGhostView : String -> Date -> Bool -> DragTracker -> Maybe Column -> ( String, Html Msg )
keyedColumnGhostView boardId today isDragging dragTracker draggedColumn =
    ( boardId ++ ":" ++ (Maybe.map Column.name draggedColumn |> Maybe.withDefault "") ++ ":ghost"
    , Html.Lazy.lazy5 columnGhostView boardId today isDragging dragTracker draggedColumn
    )


columnGhostView : String -> Date -> Bool -> DragTracker -> Maybe Column -> Html Msg
columnGhostView boardId today isDragging dragTracker draggedColumn =
    case ( isDragging, draggedColumn, dragTracker ) of
        ( True, Just column, DragTracker.Dragging clientData domData ) ->
            let
                name : String
                name =
                    Column.name column
            in
            Html.div []
                [ Html.div
                    [ class <| "todoseq-card-board-column" ++ columnCollapsedClass column
                    , style "position" "fixed"
                    , style "top" (String.fromFloat (domData.draggedNodeStartRect.y - domData.offset.y) ++ "px")
                    , style "left" (String.fromFloat (clientData.clientPos.x - domData.offset.x - clientData.offsetPos.x) ++ "px")
                    , style "width" (String.fromFloat domData.draggedNodeStartRect.width ++ "px")
                    , style "height" (String.fromFloat domData.draggedNodeStartRect.height ++ "px")
                    , style "cursor" "grabbing"
                    , style "opacity" "0.85"
                    ]
                    [ Html.div [ class "todoseq-card-board-column-header" ]
                        [ Html.div
                            [ class (columnCollapsedArrow column)
                            , attribute "aria-label" (columnCollapsedAria column)
                            ]
                            []
                        , Html.span []
                            [ Html.text <| name ]
                        , Html.span [ class "sub-text" ]
                            [ Html.text <| columnCountString column ]
                        ]
                    , Html.Keyed.ul [ class "todoseq-card-board-column-list" ]
                        (List.map (cardView initViewState today) (Column.cards (ghostBoardId boardId) column))
                    ]
                ]

        _ ->
            Html.text ""


keyedColumnView : ViewState -> Maybe String -> String -> Int -> Date -> Column -> ( String, Html Msg )
keyedColumnView state draggedId boardId columnIndex today column =
    ( boardId ++ ":" ++ Column.name column
    , columnView state draggedId boardId columnIndex today column
    )


columnView : ViewState -> Maybe String -> String -> Int -> Date -> Column -> Html Msg
columnView state draggedId boardId columnIndex today column =
    let
        domId : String
        domId =
            "todoseq-card-board-column:"
                ++ boardId
                ++ ":"
                ++ name

        isBeingDragged : Bool
        isBeingDragged =
            Just name == draggedId

        name : String
        name =
            Column.name column
    in
    Html.div [ class "todoseq-card-board-column-with-beacons" ]
        [ beacon columnBeaconType (BeaconPosition.Before name)
        , Html.div
            [ id domId
            , class <| "todoseq-card-board-column" ++ columnCollapsedClass column
            , attributeIf isBeingDragged (style "opacity" "0")
            , attribute "data-todoseq-column-id" (Column.id column)
            , attribute "data-todoseq-column-default-keyword" (Column.defaultKeyword column |> Maybe.withDefault "")
            , attribute "data-todoseq-column-writable" (Column.isWritable column |> boolAttr)
            , onDown <|
                \e ->
                    ColumnMouseDown <|
                        ( domId
                        , { uniqueId = name
                          , clientPos = Coords.fromFloatTuple e.clientPos
                          , offsetPos = Coords.fromFloatTuple e.offsetPos
                          }
                        )
            ]
            [ Html.div [ class "todoseq-card-board-column-header" ]
                [ Html.div
                    [ class (columnCollapsedArrow column)
                    , attribute "aria-label" (columnCollapsedAria column)
                    , onClick <| ToggleColumnCollapse columnIndex (not <| Column.isCollapsed column)
                    ]
                    []
                , Html.span []
                    [ Html.text <| name ]
                , Html.span [ class "sub-text" ]
                    [ Html.text <| columnCountString column ]
                ]
            , Html.Keyed.ul [ class "todoseq-card-board-column-list" ]
                (List.map (cardView state today) (Column.cards boardId column))
            ]
        , beacon columnBeaconType (BeaconPosition.After name)
        ]


cardView : ViewState -> Date -> Card -> ( String, Html Msg )
cardView state today card =
    let
        cardId : String
        cardId =
            Card.id card

        dataTags : String
        dataTags =
            card
                |> Card.allTags
                |> TagList.toStrings
                |> List.map (String.replace "/" "-")
                |> String.join " "

        taskItem : TaskItem
        taskItem =
            Card.taskItem card

        taskItemId : String
        taskItemId =
            Card.taskItemId card

        subtasksExpanded : Bool
        subtasksExpanded =
            Set.member cardId state.expandedSubtaskCards

        source : { file : String, line : Int }
        source =
            TaskItem.todoSeqSource taskItem

        sourceTitle : String
        sourceTitle =
            source.file ++ ":" ++ String.fromInt source.line

        highlightAreaClass : String
        highlightAreaClass =
            case Card.highlight today card of
                Card.HighlightCritical ->
                    "critical"

                Card.HighlightGood ->
                    "good"

                Card.HighlightImportant ->
                    "important"

                Card.HighlightNone ->
                    ""
    in
    Html.li
        [ class "todoseq-card-board-card cm-s-obsidian"
        , attributeIf (not <| String.isEmpty dataTags) (attribute "data-tags" dataTags)
        , attribute "data-todoseq-task-id" taskItemId
        , nonPropogatingOnDown <| always CardMouseDown
        , onContextMenu <| CardRightMouseDown (Card.id card)
        ]
        [ Html.div [ class ("todoseq-card-board-card-highlight-area " ++ highlightAreaClass) ]
            []
        , Html.div [ class "todoseq-card-board-card-content-area" ]
            [ Html.div [ class "todoseq-card-board-card-main-row" ]
                    [ Html.input
                        [ type_ "checkbox"
                        , class "task-list-item-checkbox todoseq-card-board-card-checkbox"
                        , stopPropogatingOnDown
                        , onCheck <| TodoSeqTaskToggled taskItemId
                    , checked <| TaskItem.isCompleted taskItem
                    , attribute "data-task" (todoSeqCheckboxState taskItem)
                    ]
                    []
                , Html.button
                    [ class "todo-task-keyword todoseq-card-board-state-keyword"
                    , type_ "button"
                    , stopPropogatingOnDown
                    , title "Click to advance TODOseq state; right click or long press for state menu"
                    , attribute "aria-label" ("TODOseq state " ++ TaskItem.todoSeqState taskItem)
                    , attribute "aria-checked" (TaskItem.isCompleted taskItem |> boolAttr)
                    , onClickWithPreventDefault <| TodoSeqKeywordClicked taskItemId
                    , onContextMenuWithStop <| TodoSeqStateMenuRequested taskItemId
                    ]
                    [ Html.text <| TaskItem.todoSeqState taskItem ]
                , Html.div
                    [ class "todoseq-card-board-card-title todoseq-task-text"
                    , id cardId
                    , title (Card.title card)
                    ]
                    [ Html.text <| Card.title card ]
                , todoSeqPriorityView taskItem
                ]
            , todoSeqMetaView today taskItem
            , subtasksView cardId subtasksExpanded (Card.descendantTasks card)
                |> when (TaskItem.hasSubtasks taskItem)
            , notesView (Card.notesId card)
                |> when (TaskItem.hasNotes taskItem)
            , Html.div [ class "todoseq-card-board-card-footer-area" ]
                [ Html.span [ class "todoseq-card-board-card-source", title sourceTitle ]
                    [ Html.text sourceTitle ]
                , cardActionButtons (Card.title card) taskItemId (Card.editButtonId card)
                ]
            ]
        ]
        |> Tuple.pair cardId


todoSeqMetaView : Date -> TaskItem -> Html Msg
todoSeqMetaView today taskItem =
    Html.div [ class "todoseq-card-board-card-todoseq-meta" ]
        [ todoSeqMaybeIconMeta "calendar" "Scheduled" (Maybe.map (millisDateString today) <| TaskItem.todoSeqScheduledDateMillis taskItem)
        , todoSeqMaybeIconMeta "alert-triangle" "Deadline" (Maybe.map (millisDateString today) <| TaskItem.todoSeqDeadlineDateMillis taskItem)
        , todoSeqMaybeIconMeta "check-circle" "Closed" (Maybe.map (millisDateString today) <| TaskItem.todoSeqClosedDateMillis taskItem)
        , todoSeqProgressBadge taskItem
        , todoSeqMaybeIconMeta "zap" "Urgency" (Maybe.map urgencyString <| TaskItem.todoSeqUrgency taskItem)
        , todoSeqTagsInline taskItem
        , todoSeqDailyBadge taskItem
        ]


todoSeqStateLabel : TaskItem -> String
todoSeqStateLabel taskItem =
    let
        groupText : String
        groupText =
            TaskItem.todoSeqGroup taskItem
                |> Maybe.map (\group -> " / " ++ group)
                |> Maybe.withDefault ""
    in
    TaskItem.todoSeqState taskItem ++ groupText


todoSeqPriorityLabel : TaskItem -> Maybe String
todoSeqPriorityLabel taskItem =
    TaskItem.todoSeqPriority taskItem
        |> Maybe.map
            (\priority ->
                case priority of
                    "high" ->
                        "A"

                    "med" ->
                        "B"

                    "low" ->
                        "C"

                    other ->
                        other
            )


todoSeqPriorityView : TaskItem -> Html Msg
todoSeqPriorityView taskItem =
    case ( TaskItem.todoSeqPriority taskItem, todoSeqPriorityLabel taskItem ) of
        ( Just priority, Just label ) ->
            Html.span
                [ class ("todoseq-priority-badge priority-" ++ priority)
                , title ("Priority " ++ priority)
                , attribute "aria-label" ("Priority " ++ priority)
                ]
                [ Html.text label ]

        _ ->
            Html.text ""


todoSeqProgressBadge : TaskItem -> Html Msg
todoSeqProgressBadge taskItem =
    let
        progress =
            TaskItem.todoSeqSubtaskProgress taskItem
    in
    if progress.total > 0 then
        todoSeqIconMeta "check-square" "Subtasks" (String.fromInt progress.completed ++ "/" ++ String.fromInt progress.total)

    else
        Html.text ""


todoSeqSourceBadge : TaskItem -> Html Msg
todoSeqSourceBadge taskItem =
    let
        source =
            TaskItem.todoSeqSource taskItem
    in
        todoSeqIconMeta "file-text" "Source" (source.file ++ ":" ++ String.fromInt source.line)


todoSeqDailyBadge : TaskItem -> Html Msg
todoSeqDailyBadge taskItem =
    if TaskItem.todoSeqIsDailyNote taskItem then
        todoSeqIconMeta "calendar-days" "Daily" "daily note"

    else
        Html.text ""


todoSeqTagsInline : TaskItem -> Html Msg
todoSeqTagsInline taskItem =
    case TaskItem.todoSeqTags taskItem of
        [] ->
            Html.text ""

        tags ->
            let
                visibleTags : List String
                visibleTags =
                    List.take 2 tags

                hiddenCount : Int
                hiddenCount =
                    List.length tags - List.length visibleTags

                visibleText : String
                visibleText =
                    visibleTags
                        |> List.map ((++) "#")
                        |> String.join " "

                value : String
                value =
                    if hiddenCount > 0 then
                        visibleText ++ " +" ++ String.fromInt hiddenCount

                    else
                        visibleText
            in
            todoSeqIconMeta "tag" "Tags" value


todoSeqBadge : String -> String -> Html Msg
todoSeqBadge label value =
    todoSeqIconMeta "info" label value


todoSeqIconMeta : String -> String -> String -> Html Msg
todoSeqIconMeta iconName label value =
    Html.span
        [ class ("todoseq-card-board-card-meta-chip todoseq-card-board-card-meta-" ++ iconName)
        , title (label ++ ": " ++ value)
        ]
        [ Html.span [ class "todoseq-card-board-card-meta-icon", attribute "aria-hidden" "true" ] [ Html.text (iconGlyph iconName) ]
        , Html.span [ class "todoseq-card-board-card-meta-value" ] [ Html.text value ]
        ]


todoSeqMaybeBadge : String -> Maybe String -> Html Msg
todoSeqMaybeBadge label maybeValue =
    todoSeqMaybeIconMeta "info" label maybeValue


todoSeqMaybeIconMeta : String -> String -> Maybe String -> Html Msg
todoSeqMaybeIconMeta iconName label maybeValue =
    maybeValue
        |> Maybe.map (todoSeqIconMeta iconName label)
        |> Maybe.withDefault (Html.text "")


iconGlyph : String -> String
iconGlyph iconName =
    case iconName of
        "alert-triangle" ->
            "⚠"

        "calendar" ->
            "📅"

        "calendar-days" ->
            "◷"

        "check-circle" ->
            "✓"

        "check-square" ->
            "☑"

        "file-text" ->
            "↗"

        "tag" ->
            "#"

        "zap" ->
            "⚡"

        _ ->
            "•"


todoSeqCheckboxState : TaskItem -> String
todoSeqCheckboxState taskItem =
    if TaskItem.isCompleted taskItem then
        "x"

    else
        case TaskItem.todoSeqGroup taskItem of
            Just "Active" ->
                "/"

            Just "active" ->
                "/"

            _ ->
                " "


urgencyString : Float -> String
urgencyString urgency =
    String.fromFloat (toFloat (round (urgency * 10)) / 10)


millisDateString : Date -> Int -> String
millisDateString today millis =
    dueDateString today (Just (Date.fromPosix Time.utc (Time.millisToPosix millis)))


cardTagsView : String -> Html Msg
cardTagsView tagsId =
    Html.div [ class "todoseq-card-board-card-tag-area", id tagsId ]
        []


notesView : String -> Html Msg
notesView notesId =
    Html.div [ class "todoseq-card-board-card-notes-area", id notesId ]
        []


visibleSubtaskLimit : Int
visibleSubtaskLimit =
    3


subtasksView : String -> Bool -> List ( String, TaskItem ) -> Html Msg
subtasksView cardId isExpanded subtasks =
    let
        totalCount : Int
        totalCount =
            List.length subtasks

        hiddenCount : Int
        hiddenCount =
            totalCount - visibleSubtaskLimit

        shouldCollapse : Bool
        shouldCollapse =
            totalCount > visibleSubtaskLimit

        visibleSubtasks : List ( String, TaskItem )
        visibleSubtasks =
            if shouldCollapse && not isExpanded then
                List.take visibleSubtaskLimit subtasks

            else
                subtasks

        toggleLabel : String
        toggleLabel =
            if isExpanded then
                "Show less · " ++ String.fromInt totalCount ++ " subtasks"

            else
                "Show " ++ String.fromInt hiddenCount ++ " more · " ++ String.fromInt totalCount ++ " subtasks"
    in
    Html.div [ class "todoseq-card-board-card-subtasks-area" ]
        [ Html.ul [ class "contains-task-list" ]
            (List.map subtaskView visibleSubtasks)
        , Html.button
            [ class "todoseq-card-board-card-subtasks-toggle"
            , type_ "button"
            , stopPropogatingOnDown
            , onClickWithPreventDefault <| ToggleCardSubtasks cardId
            ]
            [ Html.text toggleLabel ]
            |> when shouldCollapse
        ]


subtaskView : ( String, TaskItem ) -> Html Msg
subtaskView ( uniqueId, subtask ) =
    Html.li [ class "todoseq-card-board-card-subtask task-list-item" ]
        [ Html.input
            [ type_ "checkbox"
            , class "task-list-item-checkbox"
            , onClick <| TaskItemToggled <| TaskItem.id subtask
            , checked <| TaskItem.isCompleted subtask
            ]
            []
        , Html.div [ class "todoseq-card-board-card-title", id uniqueId ]
            []
        ]


taskDueDate : Date -> Maybe Date -> Html Msg
taskDueDate today dueDate =
    Html.div [ class "todoseq-card-board-card-action-area-due" ]
        [ Html.text ("Due: " ++ dueDateString today dueDate)
        ]


cardActionButtons : String -> String -> String -> Html Msg
cardActionButtons title taskItemId editButtonId =
    Html.div [ class "todoseq-card-board-card-action-area-buttons" ]
        [ Html.div
            [ class "todoseq-card-board-card-action-area-button"
            , attribute "title" "Edit TODOseq task"
            , stopPropogatingOnDown
            , onClickWithPreventDefault <| TaskItemEditClicked taskItemId
            , id editButtonId
            ]
            [ FeatherIcons.edit
                |> FeatherIcons.withSize 1
                |> FeatherIcons.withSizeUnit "em"
                |> FeatherIcons.toHtml []
            ]
        , Html.div
            [ class "todoseq-card-board-card-action-area-button"
            , attribute "title" "Change TODOseq status"
            , stopPropogatingOnDown
            , onClickWithPreventDefault <| CardStatusButtonClicked taskItemId
            ]
            [ FeatherIcons.gitPullRequest
                |> FeatherIcons.withSize 1
                |> FeatherIcons.withSizeUnit "em"
                |> FeatherIcons.toHtml []
            ]
        , Html.div
            [ class "todoseq-card-board-card-action-area-button"
            , stopPropogatingOnDown
            , onClick <| TaskItemDeleteClicked title taskItemId
            ]
            [ FeatherIcons.trash
                |> FeatherIcons.withSize 1
                |> FeatherIcons.withSizeUnit "em"
                |> FeatherIcons.toHtml []
            ]
        ]



-- HELPERS


alwaysPreventDefault : msg -> ( msg, Bool )
alwaysPreventDefault msg =
    ( msg, True )


attributeIf : Bool -> Attribute msg -> Attribute msg
attributeIf condition attribute =
    if condition then
        attribute

    else
        class ""


boolAttr : Bool -> String
boolAttr value =
    if value then
        "true"

    else
        "false"


tagHeaderBeaconType : String
tagHeaderBeaconType =
    "data-" ++ tagHeaderDragType ++ "-beacon"


beacon : String -> BeaconPosition -> Html Msg
beacon beaconType beaconPosition =
    Html.span
        [ attribute beaconType (JE.encode 0 <| BeaconPosition.encoder beaconPosition)
        , style "font-size" "0"
        ]
        []


cmdIfHasTask : String -> Model -> (TaskItemFields -> Cmd b) -> Cmd b
cmdIfHasTask id model cmd =
    model
        |> toSession
        |> Session.taskFromId id
        |> Maybe.map TaskItem.fields
        |> Maybe.map cmd
        |> Maybe.withDefault Cmd.none


columnBeaconType : String
columnBeaconType =
    "data-" ++ columnDragType ++ "-beacon"


columnCollapsedAria : Column -> String
columnCollapsedAria column =
    if Column.isCollapsed column then
        "Un-collapse"

    else
        "Collapse"


columnCollapsedArrow : Column -> String
columnCollapsedArrow column =
    if Column.isCollapsed column then
        "arrow-down"

    else
        "arrow-right"


columnCollapsedClass : Column -> String
columnCollapsedClass column =
    if Column.isCollapsed column then
        " collapsed"

    else
        ""


columnCountString : Column -> String
columnCountString column =
    if Column.isCollapsed column then
        "(" ++ (String.fromInt <| Column.cardCount column) ++ ")"

    else
        ""


displayGhostMarkdown : Model -> Cmd Msg
displayGhostMarkdown model =
    let
        dragTracker : DragTracker
        dragTracker =
            Session.dragTracker session

        session : Session
        session =
            toSession model

        currentBoard : Maybe Board
        currentBoard =
            session
                |> Session.boardConfigs
                |> SafeZipper.current
                |> Maybe.map (\bc -> Board.init (Session.uniqueId session) bc (Session.taskList session))

        ghostId : String
        ghostId =
            currentBoard
                |> Maybe.map (ghostBoardId << Board.id)
                |> Maybe.withDefault ""

        ignoreFileNameDates : Bool
        ignoreFileNameDates =
            Session.ignoreFileNameDates session

        today : Date
        today =
            Session.timeWithZone session
                |> TimeWithZone.toDate
    in
    currentBoard
        |> Maybe.map (Board.columns ignoreFileNameDates today)
        |> Maybe.withDefault []
        |> LE.find (\c -> Just (Column.name c) == DragTracker.uniqueId dragTracker)
        |> Maybe.map (Column.cards ghostId)
        |> Maybe.withDefault []
        |> InteropPorts.displayTaskMarkdown


dueDateString : Date -> Maybe Date -> String
dueDateString today dueDate =
    case dueDate of
        Just date ->
            if Date.year date == Date.year today then
                Date.format "E, MMM ddd" date

            else
                Date.format "E, MMM ddd y" date

        Nothing ->
            "n/a"


empty : Html Msg
empty =
    Html.text ""


ghostBoardId : String -> String
ghostBoardId boardId =
    boardId ++ ":ghost"


nonPropogatingOnDown : (Mouse.Event -> Msg) -> Attribute Msg
nonPropogatingOnDown =
    { stopPropagation = True, preventDefault = True }
        |> Mouse.onWithOptions "mousedown"


stopPropogatingOnDown : Attribute Msg
stopPropogatingOnDown =
    { stopPropagation = True, preventDefault = False }
        |> Mouse.onWithOptions "mousedown"
        |> (\handler -> handler (always CardMouseDown))


onContextMenuWithStop : (Mouse.Event -> Msg) -> Attribute Msg
onContextMenuWithStop =
    { stopPropagation = True, preventDefault = True }
        |> Mouse.onWithOptions "contextmenu"


onClickWithPreventDefault : msg -> Attribute msg
onClickWithPreventDefault msg =
    Html.Events.preventDefaultOn "click" (JD.map alwaysPreventDefault (JD.succeed msg))


tabHeaderClass : Maybe Int -> Int -> String
tabHeaderClass currentBoardIndex index =
    case currentBoardIndex of
        Just i ->
            if index == i - 1 then
                " is-before-active"

            else if index == i + 1 then
                " is-after-active"

            else
                ""

        Nothing ->
            ""


updateBoardOrder : DragTracker -> DragData -> Model -> Model
updateBoardOrder dragTracker { cursor, beacons } model =
    case dragTracker of
        DragTracker.Dragging clientData _ ->
            case Rect.closestTo Coords.Horizontal cursor beacons of
                Nothing ->
                    model

                Just position ->
                    mapSession (Session.moveBoard clientData.uniqueId position) model

        _ ->
            model


updateColumnOrder : DragTracker -> DragData -> Model -> Model
updateColumnOrder dragTracker { cursor, beacons } model =
    case dragTracker of
        DragTracker.Dragging clientData _ ->
            case Rect.closestTo Coords.Horizontal cursor beacons of
                Nothing ->
                    model

                Just position ->
                    mapSession (Session.moveColumn clientData.uniqueId position) model

        _ ->
            model


when : Bool -> Html Msg -> Html Msg
when shouldRender html =
    if shouldRender then
        html

    else
        empty
