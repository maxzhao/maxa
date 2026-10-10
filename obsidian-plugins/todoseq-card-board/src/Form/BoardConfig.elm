module Form.BoardConfig exposing
    ( BoardConfigForm
    , fromNewBoardForm
    , init
    , mapColumnsForm
    , safeDecoder
    , toggleShowColumnTags
    , toggleShowFilteredTags
    , updateFilterPolarity
    , updateFilterScope
    , updateName
    )

import BoardConfig exposing (BoardConfig)
import Columns exposing (Columns)
import DefaultColumnNames exposing (DefaultColumnNames)
import Filter exposing (Filter)
import Form.Column as ColumnForm
import Form.Columns as ColumnsForm exposing (ColumnsForm)
import Form.NewBoard exposing (NewBoardForm)
import Form.SafeDecoder as SD



-- TYPES


type alias BoardConfigForm =
    { columnsForm : ColumnsForm
    , filters : List Filter
    , filterPolarity : String
    , filterScope : String
    , name : String
    , showColumnTags : Bool
    , showFilteredTags : Bool
    }



-- CONSTRUCTION


fromNewBoardForm : DefaultColumnNames -> NewBoardForm -> BoardConfigForm
fromNewBoardForm defaultColumnNames newBoardConfigForm =
    let
        columnsForm : ColumnsForm
        columnsForm =
            case newBoardConfigForm.boardType of
                "todoSeqGroupsBoard" ->
                    ColumnsForm
                        [ ColumnForm.TodoSeqColumnForm False { kind = "keywordGroup", name = "Inactive", value = "inactive" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "keywordGroup", name = "Active", value = "active" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "keywordGroup", name = "Waiting", value = "waiting" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "keywordGroup", name = "Completed", value = "completed" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "keywordGroup", name = "Archived", value = "archived" }
                        ]

                "todoSeqKeywordsBoard" ->
                    ColumnsForm
                        [ ColumnForm.TodoSeqColumnForm False { kind = "state", name = "TODO", value = "TODO" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "state", name = "DOING", value = "DOING" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "state", name = "WAITING", value = "WAITING" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "state", name = "DONE", value = "DONE" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "state", name = "ARCHIVED", value = "ARCHIVED" }
                        ]

                "todoSeqPriorityBoard" ->
                    ColumnsForm
                        [ ColumnForm.TodoSeqColumnForm False { kind = "priority", name = "High", value = "high" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "priority", name = "Medium", value = "med" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "priority", name = "Low", value = "low" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "priority", name = "No Priority", value = "none" }
                        ]

                "todoSeqDateBoard" ->
                    ColumnsForm
                        [ ColumnForm.TodoSeqColumnForm False { kind = "scheduledBucket", name = "Today", value = "today" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "scheduledBucket", name = "Upcoming", value = "upcoming" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "scheduledBucket", name = "Future", value = "future" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "deadlineBucket", name = "Overdue", value = "overdue" }
                        , ColumnForm.TodoSeqColumnForm False { kind = "deadlineBucket", name = "Due Today", value = "today" }
                        ]

                "todoSeqCustomBoard" ->
                    ColumnsForm []

                _ ->
                    ColumnsForm []
    in
    { columnsForm = columnsForm
    , filters = []
    , filterPolarity = "Allow"
    , filterScope = "Both"
    , name = newBoardConfigForm.name
    , showColumnTags = True
    , showFilteredTags = True
    }


init : BoardConfig -> BoardConfigForm
init boardConfig =
    let
        filterPolarity : String
        filterPolarity =
            case BoardConfig.filterPolarity boardConfig of
                Filter.Allow ->
                    "Allow"

                Filter.Deny ->
                    "Deny"

        filterScope : String
        filterScope =
            case BoardConfig.filterScope boardConfig of
                Filter.TopLevelOnly ->
                    "TopLevelOnly"

                Filter.SubTasksOnly ->
                    "SubTasksOnly"

                Filter.Both ->
                    "Both"
    in
    { columnsForm = ColumnsForm.init <| BoardConfig.columns boardConfig
    , filters = BoardConfig.filters boardConfig
    , filterPolarity = filterPolarity
    , filterScope = filterScope
    , name = BoardConfig.name boardConfig
    , showColumnTags = BoardConfig.showColumnTags boardConfig
    , showFilteredTags = BoardConfig.showFilteredTags boardConfig
    }


safeDecoder : SD.Decoder BoardConfigForm BoardConfig
safeDecoder =
    SD.map7 BoardConfig.Config
        columnsDecoder
        filtersDecoder
        filterPolarityDecoder
        filterScopeDecoder
        nameDecoder
        showColumnTagsDecoder
        showFilteredTagsDecoder
        |> SD.map BoardConfig.fromConfig



-- MODIFICATION


mapColumnsForm : (ColumnsForm -> ColumnsForm) -> BoardConfigForm -> BoardConfigForm
mapColumnsForm fn boardConfigForm =
    { boardConfigForm | columnsForm = fn boardConfigForm.columnsForm }


toggleShowColumnTags : BoardConfigForm -> BoardConfigForm
toggleShowColumnTags boardConfigForm =
    { boardConfigForm | showColumnTags = not boardConfigForm.showColumnTags }


toggleShowFilteredTags : BoardConfigForm -> BoardConfigForm
toggleShowFilteredTags boardConfigForm =
    { boardConfigForm | showFilteredTags = not boardConfigForm.showFilteredTags }


updateFilterPolarity : String -> BoardConfigForm -> BoardConfigForm
updateFilterPolarity newPolarity boardConfigForm =
    { boardConfigForm | filterPolarity = newPolarity }


updateFilterScope : String -> BoardConfigForm -> BoardConfigForm
updateFilterScope newScope boardConfigForm =
    { boardConfigForm | filterScope = newScope }


updateName : String -> BoardConfigForm -> BoardConfigForm
updateName newName boardConfigForm =
    { boardConfigForm | name = newName }



-- PRIVATE


columnsDecoder : SD.Decoder BoardConfigForm Columns
columnsDecoder =
    ColumnsForm.safeDecoder
        |> SD.lift .columnsForm


filtersDecoder : SD.Decoder BoardConfigForm (List Filter)
filtersDecoder =
    SD.identity
        |> SD.lift .filters


filterPolarityDecoder : SD.Decoder BoardConfigForm Filter.Polarity
filterPolarityDecoder =
    (SD.custom <|
        \polarity ->
            case polarity of
                "Deny" ->
                    Ok Filter.Deny

                _ ->
                    Ok Filter.Allow
    )
        |> SD.lift .filterPolarity


filterScopeDecoder : SD.Decoder BoardConfigForm Filter.Scope
filterScopeDecoder =
    (SD.custom <|
        \scope ->
            case scope of
                "TopLevelOnly" ->
                    Ok Filter.TopLevelOnly

                "SubTasksOnly" ->
                    Ok Filter.SubTasksOnly

                _ ->
                    Ok Filter.Both
    )
        |> SD.lift .filterScope


nameDecoder : SD.Decoder BoardConfigForm String
nameDecoder =
    SD.identity
        |> SD.lift String.trim
        |> SD.lift .name


showColumnTagsDecoder : SD.Decoder BoardConfigForm Bool
showColumnTagsDecoder =
    SD.identity
        |> SD.lift .showColumnTags


showFilteredTagsDecoder : SD.Decoder BoardConfigForm Bool
showFilteredTagsDecoder =
    SD.identity
        |> SD.lift .showFilteredTags
