import { TodoSeqBoardTask } from './todoseqAdapter';
import { BoardColumn, BoardColumnPresetId, DateDisplayStrategy, DateFilterStrategy, DateSortStrategy } from './boardDomain';

export type TodoSeqCardBoardPluginSettings = TodoSeqCardBoardPluginSettingsPreV11 | TodoSeqCardBoardPluginSettingsPostV11;

type AutoCompleteTag =
  { tag : "FalseSpecified" | "NotSpecifed" | "TrueSpecified" }

type AutoComplete =
  { tag : "AutoCompleteTag", data : AutoCompleteTag }

type CompletionTag =
  { tag : "Completed" } |
  { tag : "CompletedAt", data : number } |
  { tag : "Incomplete" }

type Completion =
  { tag : "CompletedTag", data : number }

type DueTag =
  { tag : "NotSet" } |
  { tag : "SetToDate", date : number } |
  { tag : "SetToNone" }

type Due = {
  tag : "DueTag",
  data : DueTag
}

type Tag = {
  tag : "ObsidianTag",
  data : string
}

type Word =
  { tag : "Word", data : string }

type Content = AutoComplete | Completion | Due | Tag | Word;

export type TaskItemFields = {
  autoComplete : AutoCompleteTag;
  completion : CompletionTag;
  contents : Content[];
  dueFile : number | null;
  dueTag : DueTag;
  filePath : string;
      lineNumber : number;
      todoSeq: {
        closedDate: number | null;
        dailyNoteDate: number | null;
        deadlineDate: number | null;
        group: string | null;
        isDailyNote: boolean;
        priority: string | null;
        scheduledDate: number | null;
        sourceFile: string;
        sourceLine: number;
        state: string;
        subtaskCompletedCount: number;
        subtaskCount: number;
        tags: string[];
        text: string;
        urgency: number | null;
        displayText: string;
      } | null;
  notes : string;
  originalBlock : string;
  originalLine : string;
  tags : string[];
  title : string[];
}

export type TaskItem = {
  fields : TaskItemFields;
  subFields : TaskItemFields[];
  todoSeq?: TodoSeqBoardTask;
}

export type TodoSeqCardBoardPluginSettingsPostV11 = {
  data : {
    boardConfigs : ({
        todoSeqColumnPreset?: BoardColumnPresetId;
        todoSeqColumns?: BoardColumn[];
        columns : ({
        tag : "completed"
        data : {
          collapsed : boolean;
          name : string;
          index : number;
          limit : number;
        }
      } | {
        tag : "dated"
        data : {
          collapsed : boolean;
          name : string;
          range : ({
            tag : "after"
            data : number
          } | {
            tag : "before"
            data : number
          } | {
            tag : "between"
            data : {
              from : number
              to : number
            }
          })
        }
      } | {
        tag : "namedTag"
        data : {
          collapsed : boolean;
          name : string;
          tag : string;
        }
      } | {
        tag : "otherTags"
        data : {
          collapsed : boolean;
          name : string;
        }
      } | {
        tag : "undated"
        data : {
          collapsed : boolean;
          name : string;
        }
      } | {
        tag : "untagged"
        data : {
          collapsed : boolean;
          name : string;
        }
      } | {
        tag : "todoSeq"
        data : {
          id: string;
          collapsed: boolean;
          name: string;
            columnType: "keyword" | "group" | "custom";
            kind?: string;
            match?: Record<string, unknown>;
            writable?: boolean;
            keywords: string[];
        group: string | null;
        defaultKeyword: string | null;
        }
      })[];
      filters : Filter[];
        filterPolarity: "Allow" | "Deny";
        filterScope: "TopLevelOnly" | "SubTasksOnly" | "Both";
        showColumnTags : boolean;
      showFilteredTags : boolean;
      name : string
    })[];
    globalSettings : {
      todoSeq?: {
        columnPreset: BoardColumnPresetId;
        columnPresetOptions?: BoardColumnPresetId[];
        customColumns: BoardColumn[];
        dateDisplay: DateDisplayStrategy;
        dateSort: DateSortStrategy;
        dateFilter: DateFilterStrategy | null;
      }
      defaultColumnNames : {
        inactive : string;
        active : string;
        waiting : string;
        completed : string;
        archived : string;
      }
      filters : Filter[];
      firstDayOfWeek : "FromLocale" | "Mon" | "Tue" | "Wed" | "Thu" | "Fri" | "Sat" | "Sun";
      ignoreFileNameDates : boolean;
      taskCompletionFormat : "NoCompletion" | "ObsidianCardBoard" | "ObsidianDataview" | "ObsidianTasks";
      taskCompletionInLocalTime : boolean;
      taskCompletionShowUtcOffset : boolean;
    }
  };
  version : string
}

type TodoSeqCardBoardPluginSettingsPreV11 = {
  data : {
    boardConfigs : (
      { data : {
          columns : { displayTitle : string; tag : string }[];
          showColumnTags : boolean;
          completedCount : number;
          filters : ({ data : string; tag : "tagFilter" } | { data : string; tag : "pathFilter" } | { data : string; tag : "fileFilter" })[];
          filterPolarity : "Allow" | "Deny";
          showFilteredTags : boolean;
          includeOthers : boolean;
          includeUntagged : boolean;
          title : string
        };
        tag : "tagBoardConfig" }
      | { data : {
          completedCount : number;
          filters : Filter[];
          filterPolarity : "Allow" | "Deny";
          showFilteredTags : boolean;
          includeUndated : boolean;
          title : string
        };
        tag : "dateBoardConfig"
      }
    )[];
    globalSettings : {
      taskCompletionFormat : "NoCompletion" | "ObsidianCardBoard" | "ObsidianDataview" | "ObsidianTasks";
      columnNames : {
        today : string;
        tomorrow : string;
        future : string;
        undated : string;
        others : string;
        untagged : string
        completed : string;
      }
      ignoreFileNameDates : boolean;
    }
  };
  version : string
}

export type Filter = { data : string; tag : "tagFilter" } | { data : string; tag : "pathFilter" } | { data : string; tag : "fileFilter" };
