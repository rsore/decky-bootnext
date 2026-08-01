import {
  ButtonItem,
  ConfirmModal,
  PanelSection,
  PanelSectionRow,
  showModal,
  staticClasses,
} from "@decky/ui";

import {
  addEventListener,
  callable,
  definePlugin,
  removeEventListener,
  toaster,
} from "@decky/api";

import { useCallback, useEffect, useState } from "react";

import { FaRandom, FaSyncAlt, FaTimesCircle } from "react-icons/fa";

declare const SteamClient: {
  System: {
    RestartPC(): unknown;
  };
};

interface BootEntry {
  id: string;
  label: string;
  active: boolean;
}

interface BootState {
  current: string | null;
  next: string | null;
  order: string[];
  entries: BootEntry[];
}

const getBootState = callable<[], BootState>("get_boot_state");
const setBootNext = callable<[entryId: string], BootState>("set_boot_next");
const clearBootNext = callable<[], BootState>("clear_boot_next");

function Content() {
  const [bootState, setBootState] = useState<BootState>();
  const [error, setError] = useState<string>();
  const [loading, setLoading] = useState(true);
  const [settingEntry, setSettingEntry] = useState<string>();

  const refresh = useCallback(async () => {
    setLoading(true);
    setError(undefined);

    try {
      setBootState(await getBootState());
    } catch (reason) {
      setBootState(undefined);
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const selectEntry = async (entry: BootEntry, restart: boolean) => {
    setSettingEntry(entry.id);

    try {
      const updatedState = await setBootNext(entry.id);
      setBootState(updatedState);

      if (restart) {
        SteamClient.System.RestartPC();
      }
    } catch (reason) {
      console.error("Failed to set next boot:", reason);
    } finally {
      setSettingEntry(undefined);
    }
  };

  const confirmSelection = (entry: BootEntry) => {
    showModal(
      <ConfirmModal
        strTitle="Set next boot?"
        strDescription={`Boot into ${entry.label} next? This changes only the next boot; the normal boot order remains unchanged.`}
        strOKButtonText="Set only"
        strCancelButtonText="Cancel"
        strMiddleButtonText="Set & restart"
        onOK={() => void selectEntry(entry, false)}
        onMiddleButton={() => void selectEntry(entry, true)}
      />
    );
  };

  const clearNextEntry = async () => {
    setLoading(true);

    try {
      setBootState(await clearBootNext());
    } catch (reason) {
      console.error("Failed to clear next boot:", reason);
    } finally {
      setLoading(false);
    }
  };

  const confirmClearNext = () => {
    showModal(
      <ConfirmModal
        strTitle="Clear next boot?"
        strDescription="Remove the next-boot override? The system will use the normal UEFI boot order."
        strOKButtonText="Clear"
        strCancelButtonText="Cancel"
        onOK={() => void clearNextEntry()}
      />
    );
  };

  return (
    <>
      <PanelSection title="Actions">
        <PanelSectionRow>
          <ButtonItem
            layout="below"
            onClick={() => void refresh()}
            disabled={loading || settingEntry !== undefined}
          >
            <FaSyncAlt /> {loading ? "Refreshing…" : "Refresh boot entries"}
          </ButtonItem>
        </PanelSectionRow>

        <PanelSectionRow>
          <ButtonItem
            layout="below"
            onClick={confirmClearNext}
            disabled={
              loading || settingEntry !== undefined || bootState?.next == null
            }
          >
            <FaTimesCircle /> Clear next boot
          </ButtonItem>
        </PanelSectionRow>
      </PanelSection>

      <PanelSection title="Choose next boot">
        {loading && !bootState && (
          <PanelSectionRow>Loading UEFI boot entries…</PanelSectionRow>
        )}

        {error && (
          <PanelSectionRow>
            <div
              style={{
                boxSizing: "border-box",
                width: "100%",
                padding: "8px 12px",
                color: "#ff8a8a",
                whiteSpace: "normal",
                overflowWrap: "anywhere",
              }}
            >
              {error}
            </div>
          </PanelSectionRow>
        )}

        {bootState?.entries.map((entry) => {
          const isCurrent = entry.id === bootState.current;
          const isNext = entry.id === bootState.next;

          let status: string | undefined;

          if (!entry.active) {
            status = "Inactive";
          } else if (isCurrent && isNext) {
            status = "Current & next";
          } else if (isCurrent) {
            status = "Current";
          } else if (isNext) {
            status = "Next boot";
          }

          if (settingEntry === entry.id) {
            status = "Setting next boot…";
          }

          return (
            <PanelSectionRow key={entry.id}>
              <ButtonItem
                onClick={() => confirmSelection(entry)}
                disabled={
                  loading ||
                  settingEntry !== undefined ||
                  !entry.active ||
                  isNext
                }
              >
                <div
                  style={{
                    display: "flex",
                    flexDirection: "column",
                    gap: "2px",
                  }}
                >
                  <div>{entry.label}</div>

                  {status && (
                    <div
                      style={{
                        fontSize: "0.8em",
                        opacity: 0.7,
                      }}
                    >
                      {status}
                    </div>
                  )}
                </div>
              </ButtonItem>
            </PanelSectionRow>
          );
        })}
      </PanelSection>
    </>
  );
}

export default definePlugin(() => {
  console.log("BootNext initializing");

  const errorListener = addEventListener<[message: string]>(
    "bootnext_error",
    (message) => {
      toaster.toast({
        title: "BootNext",
        body: message,
        critical: true,
        showToast: true,
        playSound: true,
        duration: 6000,
      });
    }
  );

  return {
    name: "BootNext",
    titleView: <div className={staticClasses.Title}>BootNext</div>,
    content: <Content />,
    icon: <FaRandom />,

    onDismount() {
      removeEventListener("bootnext_error", errorListener);
      console.log("BootNext unloading");
    },
  };
});
