module Form.NewColumnTests exposing (suite)

import Expect
import Form.Column as ColumnForm
import Form.Columns as ColumnsForm
import Form.NewColumn as NewColumnForm
import Form.SafeDecoder as SD
import Test exposing (..)


suite : Test
suite =
    concat
        [ default
        , optionsForSelect
        , safeDecoder
        , updateColumnType
        , updateName
        ]


default : Test
default =
    describe "default"
        [ test "returns config with no name" <|
            \() ->
                NewColumnForm.default
                    |> .name
                    |> Expect.equal ""
        , test "returns config with an empty columnType" <|
            \() ->
                NewColumnForm.default
                    |> .columnType
                    |> Expect.equal ""
        ]


optionsForSelect : Test
optionsForSelect =
    describe "optionsForSelect"
        [ test "returns TODOseq task property options if there is an empty columnsForm" <|
            \() ->
                NewColumnForm.optionsForSelect ColumnsForm.empty { name = "", columnType = "State" }
                    |> Expect.equal
                        [ { isSelected = True, text = "TODOseq state keyword", value = "State" }
                        , { isSelected = False, text = "TODOseq keyword group", value = "KeywordGroup" }
                        , { isSelected = False, text = "Priority", value = "Priority" }
                        , { isSelected = False, text = "SCHEDULED bucket", value = "ScheduledBucket" }
                        , { isSelected = False, text = "DEADLINE bucket", value = "DeadlineBucket" }
                        , { isSelected = False, text = "CLOSED bucket", value = "ClosedBucket" }
                        , { isSelected = False, text = "Tag", value = "Tag" }
                        , { isSelected = False, text = "Urgency bucket", value = "UrgencyBucket" }
                        , { isSelected = False, text = "Daily note", value = "DailyNote" }
                        , { isSelected = False, text = "Source file/folder", value = "Source" }
                        , { isSelected = False, text = "Subtask progress", value = "SubtaskProgress" }
                        , { isSelected = False, text = "Custom TODOseq property filter", value = "CustomFilter" }
                        ]
        , test "selects the first TODOseq property if the selection is invalid" <|
            \() ->
                NewColumnForm.optionsForSelect ColumnsForm.empty { name = "", columnType = "xxx" }
                    |> List.head
                    |> Expect.equal (Just { isSelected = True, text = "TODOseq state keyword", value = "State" })
        , test "keeps SCHEDULED and DEADLINE as separate options" <|
            \() ->
                NewColumnForm.optionsForSelect ColumnsForm.empty { name = "", columnType = "DeadlineBucket" }
                    |> List.filter .isSelected
                    |> Expect.equal [ { isSelected = True, text = "DEADLINE bucket", value = "DeadlineBucket" } ]
        ]


safeDecoder : Test
safeDecoder =
    describe "safeDecoder"
        [ test "decodes state property as a TODOseq state placeholder column" <|
            \() ->
                { name = "", columnType = "State" }
                    |> SD.run NewColumnForm.safeDecoder
                    |> Expect.equal (Ok <| Just (ColumnForm.TodoSeqColumnForm False { kind = "state", name = "TODOseq State", value = "TODO" }))
        , test "decodes deadline property distinctly from scheduled property" <|
            \() ->
                { name = "", columnType = "DeadlineBucket" }
                    |> SD.run NewColumnForm.safeDecoder
                    |> Expect.equal (Ok <| Just (ColumnForm.TodoSeqColumnForm False { kind = "deadlineBucket", name = "TODOseq Deadline Today", value = "today" }))
        , test "decodes read-only urgency property as an explicit TODOseq placeholder column" <|
            \() ->
                { name = "", columnType = "UrgencyBucket" }
                    |> SD.run NewColumnForm.safeDecoder
                    |> Expect.equal (Ok <| Just (ColumnForm.TodoSeqColumnForm False { kind = "urgencyBucket", name = "TODOseq Urgency", value = "high" }))
        , test "decodes an INVALID column" <|
            \() ->
                { name = "foo", columnType = "XXXXXXXXXX" }
                    |> SD.run NewColumnForm.safeDecoder
                    |> Expect.equal (Ok Nothing)
        ]


updateColumnType : Test
updateColumnType =
    describe "updateColumnType"
        [ test "updates the column type" <|
            \() ->
                NewColumnForm.default
                    |> NewColumnForm.updateColumnType "foo"
                    |> .columnType
                    |> Expect.equal "foo"
        ]


updateName : Test
updateName =
    describe "updateName"
        [ test "updates the board name" <|
            \() ->
                NewColumnForm.default
                    |> NewColumnForm.updateName "foo"
                    |> .name
                    |> Expect.equal "foo"
        ]
