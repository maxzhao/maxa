export interface StateTransitionSettings {
  defaultInactive: string;
  defaultActive: string;
  defaultCompleted: string;
  transitionStatements: string[];
}

export const DefaultStateTransitionSettings: StateTransitionSettings = {
  defaultInactive: 'TODO',
  defaultActive: 'DOING',
  defaultCompleted: 'DONE',
  transitionStatements: [],
};
