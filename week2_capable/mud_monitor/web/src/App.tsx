import { Route, Routes } from "react-router";
import Layout from "./components/Layout";
import Dashboard from "./pages/Dashboard";
import HealthPage from "./pages/Health";
import Entities from "./pages/knowledge/Entities";
import Frontier from "./pages/knowledge/Frontier";
import Knowledge from "./pages/knowledge/Knowledge";
import Overview from "./pages/knowledge/Overview";
import RoomDetail from "./pages/knowledge/RoomDetail";
import Rooms from "./pages/knowledge/Rooms";
import Manager from "./pages/Manager";
import SessionDetail from "./pages/SessionDetail";
import Sessions from "./pages/Sessions";
import Telnet from "./pages/Telnet";

export default function App() {
  return (
    <Routes>
      <Route element={<Layout />}>
        <Route index element={<Dashboard />} />
        <Route path="sessions" element={<Sessions />} />
        <Route path="sessions/:id" element={<SessionDetail />} />
        <Route path="manager" element={<Manager />} />
        <Route path="telnet" element={<Telnet />} />
        {/* Nested routes rather than useState tabs: a room the agent got wrong
            is something you paste into chat, and "click Knowledge, then Rooms,
            then find #7" is not a link. */}
        <Route path="knowledge" element={<Knowledge />}>
          <Route index element={<Overview />} />
          <Route path="rooms" element={<Rooms />} />
          <Route path="rooms/:id" element={<RoomDetail />} />
          <Route path="entities" element={<Entities />} />
          <Route path="frontier" element={<Frontier />} />
        </Route>
        <Route path="health" element={<HealthPage />} />
      </Route>
    </Routes>
  );
}
