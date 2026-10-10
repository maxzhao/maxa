module Form.NewBoard exposing
    ( NewBoardForm
    , OptionsForSelect
  , default
  , optionsForSelect
  , updateBoardType
  , updateName
  )

-- TYPES


type alias NewBoardForm =
    { name : String
    , boardType : String
    }


type alias OptionsForSelect =
    { isSelected : Bool
    , text : String
    , value : String
    }



-- INITIALIZE


default : NewBoardForm
default =
    { name = ""
    , boardType = "todoSeqGroupsBoard"
    }



-- INFO


optionsForSelect : NewBoardForm -> List OptionsForSelect
optionsForSelect newBoardForm =
    [ { isSelected = newBoardForm.boardType == "todoSeqGroupsBoard"
      , text = "TODOseq Groups Board"
      , value = "todoSeqGroupsBoard"
      }
    , { isSelected = newBoardForm.boardType == "todoSeqKeywordsBoard"
      , text = "TODOseq Keywords Board"
      , value = "todoSeqKeywordsBoard"
      }
    , { isSelected = newBoardForm.boardType == "todoSeqPriorityBoard"
      , text = "TODOseq Priority Board"
      , value = "todoSeqPriorityBoard"
      }
    , { isSelected = newBoardForm.boardType == "todoSeqDateBoard"
      , text = "TODOseq Date Board"
      , value = "todoSeqDateBoard"
      }
    , { isSelected = newBoardForm.boardType == "todoSeqCustomBoard"
      , text = "TODOseq Custom Board"
      , value = "todoSeqCustomBoard"
      }
    ]



-- MODIFICATION


updateBoardType : String -> NewBoardForm -> NewBoardForm
updateBoardType newType newBoardForm =
    { newBoardForm | boardType = newType }


updateName : String -> NewBoardForm -> NewBoardForm
updateName newName newBoardForm =
    { newBoardForm | name = newName }
