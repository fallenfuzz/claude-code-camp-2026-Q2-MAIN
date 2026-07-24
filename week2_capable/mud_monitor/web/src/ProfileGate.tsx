import { createContext, useContext, useEffect, useState, type ReactNode } from "react";

export interface Profile {
  id: string;
  label: string;
  available: boolean;
}

interface ProfileState {
  profiles: Profile[];
  selected: string;
  select: (id: string) => void;
}

const STORAGE_KEY = "mud-monitor.profile";
const ProfileContext = createContext<ProfileState | null>(null);

function setProfileCookie(id: string) {
  document.cookie = `mud_monitor_profile=${encodeURIComponent(id)}; Path=/; SameSite=Strict`;
}

export function useProfile() {
  const value = useContext(ProfileContext);
  if (!value) throw new Error("useProfile must be used inside ProfileGate");
  return value;
}

export default function ProfileGate({ children }: { children: ReactNode }) {
  const [profiles, setProfiles] = useState<Profile[] | null>(null);
  const [selected, setSelected] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    fetch("/api/v1/profiles")
      .then(async (response) => {
        if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
        return response.json() as Promise<{ profiles: Profile[] }>;
      })
      .then(({ profiles: available }) => {
        const saved = localStorage.getItem(STORAGE_KEY) || "";
        const match = available.find((profile) => profile.available && profile.id.toLowerCase() === saved.toLowerCase());
        if (match) {
          setProfileCookie(match.id);
          setSelected(match.id);
        }
        setProfiles(available);
      })
      .catch((cause: unknown) => setError(cause instanceof Error ? cause.message : String(cause)));
  }, []);

  const select = (id: string) => {
    localStorage.setItem(STORAGE_KEY, id);
    setProfileCookie(id);
    setSelected(id);
  };

  if (error) return <main><p className="error">Could not load profiles: {error}</p></main>;
  if (!profiles) return <main><p>Loading player profiles…</p></main>;
  if (!selected) {
    return (
      <main className="profile-required">
        <h1>Select a player</h1>
        <p>Mud Monitor keeps every player’s knowledge and history isolated.</p>
        <select value="" onChange={(event) => select(event.target.value)}>
          <option value="" disabled>Choose a profile…</option>
          {profiles.filter((profile) => profile.available).map((profile) => (
            <option key={profile.id} value={profile.id}>{profile.label}</option>
          ))}
        </select>
      </main>
    );
  }

  return (
    <ProfileContext.Provider value={{ profiles, selected, select }}>
      {children}
    </ProfileContext.Provider>
  );
}
