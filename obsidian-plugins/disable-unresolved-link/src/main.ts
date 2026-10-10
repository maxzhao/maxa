// @ts-nocheck
// Disable Unresolved Link Creation Plugin
// Asks for confirmation before creating new notes when clicking unresolved wikilinks.

import { Modal, Plugin, Setting } from "obsidian";

class ConfirmCreateModal extends Modal {
  constructor(app, linktext, onConfirm) {
    super(app);
    this.linktext = linktext;
    this.onConfirm = onConfirm;
  }

  onOpen() {
    const { contentEl } = this;
    contentEl.createEl("p", { text: `"${this.linktext}" does not exist.` });
    contentEl.createEl("p", { text: "Create this note?" });

    new Setting(contentEl)
      .addButton((btn) =>
        btn.setButtonText("Create").setCta().onClick(() => {
          this.close();
          this.onConfirm();
        })
      )
      .addButton((btn) =>
        btn.setButtonText("Cancel").onClick(() => {
          this.close();
        })
      );
  }

  onClose() {
    this.contentEl.empty();
  }
}

class DisableUnresolvedLinkPlugin extends Plugin {
  async onload() {
    const original = this.app.workspace.openLinkText.bind(this.app.workspace);

    this.app.workspace.openLinkText = async (linktext, sourcePath, newLeaf, openViewState) => {
      const resolved = this.app.metadataCache.getFirstLinkpathDest(linktext, sourcePath);

      if (!resolved) {
        // File does not exist — ask for confirmation
        return new Promise((resolve) => {
          new ConfirmCreateModal(this.app, linktext, () => {
            original(linktext, sourcePath, newLeaf, openViewState).then(resolve);
          }).open();
        });
      }

      return original(linktext, sourcePath, newLeaf, openViewState);
    };
  }

  onunload() {}
}

export default DisableUnresolvedLinkPlugin;
