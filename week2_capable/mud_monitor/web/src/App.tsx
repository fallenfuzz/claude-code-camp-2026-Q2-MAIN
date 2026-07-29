import { Route, Routes } from "react-router";
import Layout from "./components/Layout";
import Dashboard from "./pages/Dashboard";
import Errors from "./pages/Errors";
import HealthPage from "./pages/Health";
import Journal from "./pages/Journal";
import Entities from "./pages/knowledge/Entities";
import Frontier from "./pages/knowledge/Frontier";
import Knowledge from "./pages/knowledge/Knowledge";
import KnowledgeMap from "./pages/knowledge/Map";
import Overview from "./pages/knowledge/Overview";
import Player from "./pages/knowledge/Player";
import Progression from "./pages/knowledge/Progression";
import Regions from "./pages/knowledge/Regions";
import RoomDetail from "./pages/knowledge/RoomDetail";
import Rooms from "./pages/knowledge/Rooms";
import Manager from "./pages/Manager";
import ReportDetail from "./pages/ReportDetail";
import Reports from "./pages/Reports";
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
        {/* Batch test runs. Flat rather than nested under sessions: a report is
            about a set of sessions, not a view of one. */}
        <Route path="reports" element={<Reports />} />
        <Route path="reports/:id" element={<ReportDetail />} />
        <Route path="manager" element={<Manager />} />
        <Route path="telnet" element={<Telnet />} />
        <Route path="errors" element={<Errors />} />
        <Route path="journal" element={<Journal />} />
        {/* Nested routes rather than useState tabs: a room the agent got wrong
            is something you paste into chat, and "click Knowledge, then Rooms,
            then find #7" is not a link. */}
        <Route path="knowledge" element={<Knowledge />}>
          <Route index element={<Overview />} />
          <Route path="rooms" element={<Rooms />} />
          <Route path="rooms/:id" element={<RoomDetail />} />
          <Route path="map" element={<KnowledgeMap />} />
          <Route path="entities" element={<Entities />} />
          <Route path="frontier" element={<Frontier />} />
          <Route path="regions" element={<Regions />} />
          <Route path="player" element={<Player />} />
          <Route path="progression" element={<Progression />} />
        </Route>
        <Route path="health" element={<HealthPage />} />
      </Route>
    </Routes>
  );
}
