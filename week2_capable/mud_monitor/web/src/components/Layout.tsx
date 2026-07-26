import { Link, Outlet } from "react-router";
import { useProfile } from "../ProfileGate";

export default function Layout() {
  const { profiles, selected, select } = useProfile();
  return (
    <>
      <header className="topbar">
        <Link to="/" className="brand">
          Mud Monitor
        </Link>
        <nav>
          <Link to="/">Dashboard</Link>
          <Link to="/sessions">Sessions</Link>
          <Link to="/manager">Manager</Link>
          <Link to="/telnet">Telnet</Link>
          <Link to="/errors">Errors</Link>
          <Link to="/knowledge">Knowledge</Link>
          <Link to="/journal">Change Log</Link>
          <Link to="/health">Health</Link>
        </nav>
        <label className="profile-selector">
          <span>Player</span>
          <select value={selected} onChange={(event) => select(event.target.value)}>
            {profiles.filter((profile) => profile.available).map((profile) => (
              <option key={profile.id} value={profile.id}>{profile.label}</option>
            ))}
          </select>
        </label>
      </header>
      <main>
        <Outlet key={selected} />
      </main>
    </>
  );
}
