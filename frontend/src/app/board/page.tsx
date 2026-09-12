import BoardPage from "@/components/board/BoardPage";
import { UserProvider } from "@/lib/UserContext";

export default function Board() {
  return (
    <UserProvider>
      <BoardPage />
    </UserProvider>
  );
}
