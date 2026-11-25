// What of a UI fault leaves the device: its category alone, never its text (which can hold editor keys made from file
// paths). The app sorts its faults by this list (apps/mbui/src/stillfail/ui_faults.mbt is made from it by
// scripts/ui-faults.ts) and the core takes no other category, whatever an app sends.

/** How a fault's text is recognised: the whole of it, or how it starts. */
export const UI_FAULTS: readonly { said: string; whole: boolean; category: string }[] = [
  { said: "Ctx::editor: one Field given to two editors in one build (", whole: false, category: "editor field reused" },
  { said: "Ctx::editor: a Field given to ", whole: false, category: "editor field already in tree" },
  { said: "field: one Field given to two fields of the tree's: a Field is one editor's", whole: true, category: "tree field reused" },
  { said: "scene: a frame put together round layers drawn again where they were not kept: ", whole: false, category: "scene layer conflict" },
  { said: "presented beside a node of the tree, drawn by the old frame: a kind of panel panel_node does not take yet", whole: true, category: "panel cannot be presented" },
  // Which step of a chat's list lost what was sent from here (the app's chat_sent_unseen_said): each set of its flags is
  // a category of its own, and anything else after the same words is the one below.
  ...chatSentUnseen(),
  { said: "chat sent unseen: ", whole: false, category: "chat sent unseen" },
];

/** Each set of the flags chat_sent_unseen_said gives (listed, row, staged, held, sending): words of its own alone. */
function chatSentUnseen(): { said: string; whole: boolean; category: string }[] {
  const out: { said: string; whole: boolean; category: string }[] = [];
  for (let i = 0; i < 32; i++) {
    const b = (bit: number) => (i >> bit) & 1;
    const said = `chat sent unseen: listed=${b(4)} row=${b(3)} staged=${b(2)} held=${b(1)} sending=${b(0)}`;
    out.push({ said, whole: true, category: said });
  }
  return out;
}

/** Any other fault. */
export const UI_FAULT_OTHER = "UI fault";

/** The categories a UI fault may be reported as. */
export const UI_FAULT_CATEGORIES: readonly string[] = [UI_FAULT_OTHER, ...UI_FAULTS.map((f) => f.category)];
