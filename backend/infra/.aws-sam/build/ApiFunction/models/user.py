from dataclasses import dataclass, field
from datetime import datetime


@dataclass
class User:
    """
    Represents a FiatLux user.

    The user_id comes from Clerk authentication (sub claim in JWT).
    """
    user_id: str                          # Clerk user ID (primary key)
    email: str
    display_name: str = ""

    # Timestamps
    created_at: datetime = field(default_factory=datetime.utcnow)
    updated_at: datetime = field(default_factory=datetime.utcnow)

    def to_dict(self) -> dict:
        return {
            "user_id": self.user_id,
            "email": self.email,
            "display_name": self.display_name,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
        }

    @classmethod
    def from_dict(cls, data: dict) -> "User":
        return cls(
            user_id=data["user_id"],
            email=data["email"],
            display_name=data.get("display_name", ""),
            created_at=datetime.fromisoformat(data["created_at"]),
            updated_at=datetime.fromisoformat(data["updated_at"]),
        )
