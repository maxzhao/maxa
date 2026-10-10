module Form.NewColumn exposing
    ( NewColumnForm
    , default
    , optionsForSelect
    , safeDecoder
    , todoSeqAttributeDescription
    , todoSeqAttributeOptions
    , updateColumnType
    , updateName
    )

import Form.Column as ColumnForm exposing (ColumnForm)
import Form.Columns exposing (ColumnsForm)
import Form.SafeDecoder as SD
import Form.Select exposing (Option)
import List.Extra as LE



-- TYPES


type alias NewColumnForm =
    { name : String
    , columnType : String
    }



-- INITIALIZE


default : NewColumnForm
default =
    { name = ""
    , columnType = ""
    }



-- DECODE


safeDecoder : SD.Decoder NewColumnForm (Maybe ColumnForm)
safeDecoder =
    SD.custom <|
        \form ->
            case form.columnType of
                "State" ->
                    todoSeqColumn "state" "TODO" "TODOseq State" form

                "KeywordGroup" ->
                    todoSeqColumn "keywordGroup" "active" "TODOseq Keyword Group" form

                "Priority" ->
                    todoSeqColumn "priority" "high" "TODOseq Priority" form

                "ScheduledBucket" ->
                    todoSeqColumn "scheduledBucket" "today" "TODOseq Scheduled Today" form

                "DeadlineBucket" ->
                    todoSeqColumn "deadlineBucket" "today" "TODOseq Deadline Today" form

                "ClosedBucket" ->
                    todoSeqColumn "closedBucket" "closed" "TODOseq Closed" form

                "Tag" ->
                    todoSeqColumn "tag" "tag" "TODOseq Tag" form

                "UrgencyBucket" ->
                    todoSeqColumn "urgencyBucket" "high" "TODOseq Urgency" form

                "DailyNote" ->
                    todoSeqColumn "dailyNote" "daily" "TODOseq Daily Note" form

                "Source" ->
                    todoSeqColumn "source" "" "TODOseq Source" form

                "SubtaskProgress" ->
                    todoSeqColumn "subtaskProgress" "inProgress" "TODOseq Subtasks" form

                "CustomFilter" ->
                    todoSeqColumn "customFilter" "TODO" "TODOseq Custom Filter" form

                _ ->
                    Ok <| Nothing



-- INFO


optionsForSelect : ColumnsForm -> NewColumnForm -> List Option
optionsForSelect _ newColumnConfigForm =
    let
        allColumns : List Option
        allColumns =
            todoSeqAttributeOptions newColumnConfigForm
    in
    if List.any .isSelected allColumns then
        allColumns

    else
        allColumns
            |> LE.updateAt 0 (\ofs -> { ofs | isSelected = True })


todoSeqAttributeOptions : NewColumnForm -> List Option
todoSeqAttributeOptions newColumnConfigForm =
    [ { isSelected = newColumnConfigForm.columnType == "State", text = "TODOseq state keyword", value = "State" }
    , { isSelected = newColumnConfigForm.columnType == "KeywordGroup", text = "TODOseq keyword group", value = "KeywordGroup" }
    , { isSelected = newColumnConfigForm.columnType == "Priority", text = "Priority", value = "Priority" }
    , { isSelected = newColumnConfigForm.columnType == "ScheduledBucket", text = "SCHEDULED bucket", value = "ScheduledBucket" }
    , { isSelected = newColumnConfigForm.columnType == "DeadlineBucket", text = "DEADLINE bucket", value = "DeadlineBucket" }
    , { isSelected = newColumnConfigForm.columnType == "ClosedBucket", text = "CLOSED bucket", value = "ClosedBucket" }
    , { isSelected = newColumnConfigForm.columnType == "Tag", text = "Tag", value = "Tag" }
    , { isSelected = newColumnConfigForm.columnType == "UrgencyBucket", text = "Urgency bucket", value = "UrgencyBucket" }
    , { isSelected = newColumnConfigForm.columnType == "DailyNote", text = "Daily note", value = "DailyNote" }
    , { isSelected = newColumnConfigForm.columnType == "Source", text = "Source file/folder", value = "Source" }
    , { isSelected = newColumnConfigForm.columnType == "SubtaskProgress", text = "Subtask progress", value = "SubtaskProgress" }
    , { isSelected = newColumnConfigForm.columnType == "CustomFilter", text = "Custom TODOseq property filter", value = "CustomFilter" }
    ]


todoSeqAttributeDescription : String -> String
todoSeqAttributeDescription columnType =
    case columnType of
        "State" ->
            "Writable: moving a card writes the target TODOseq state keyword."

        "KeywordGroup" ->
            "Writable: moving a card writes the group's default TODOseq keyword."

        "Priority" ->
            "Writable model: priority writer is implemented by the TODOseq property writer task."

        "ScheduledBucket" ->
            "SCHEDULED bucket; separate from DEADLINE and never merged into CardBoard due."

        "DeadlineBucket" ->
            "DEADLINE bucket; separate from SCHEDULED and never merged into CardBoard due."

        "ClosedBucket" ->
            "Read-only filter/display column for CLOSED."

        "Tag" ->
            "Read-only in this task: matches TODOseq tags; tag writer comes later."

        "UrgencyBucket" ->
            "Read-only filter/display column based on TODOseq urgency."

        "DailyNote" ->
            "Read-only filter/display column for TODOseq daily-note tasks."

        "Source" ->
            "Read-only filter/display column for source file or folder. Use the column name as the file/folder value after adding."

        "SubtaskProgress" ->
            "Read-only filter/display column for subtask progress."

        "CustomFilter" ->
            "Read-only combined TODOseq property predicate for future query adapters."

        _ ->
            "Choose a TODOseq task property; columns now match TODOseq task attributes rather than legacy CardBoard due/tag modes."



-- MODIFICATION


updateColumnType : String -> NewColumnForm -> NewColumnForm
updateColumnType newType newColumnForm =
    { newColumnForm | columnType = newType }


fallbackName : String -> String -> String
fallbackName defaultName name =
    if String.trim name == "" then
        defaultName

    else
        name


updateName : String -> NewColumnForm -> NewColumnForm
updateName newName newColumnForm =
    { newColumnForm | name = newName }


todoSeqColumn : String -> String -> String -> NewColumnForm -> Result Never (Maybe ColumnForm)
todoSeqColumn kind value defaultName form =
    Ok <|
        Just <|
            ColumnForm.TodoSeqColumnForm False
                { kind = kind
                , name = fallbackName defaultName form.name
                , value = value
                }
