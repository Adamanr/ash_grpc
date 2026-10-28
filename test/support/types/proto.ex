# Hand-written protobuf modules (what protoc-gen-elixir emits for the schema in
# `AshGrpc.Test.Types.Schema`). They are the oracle for the mapping and codec tests.

defmodule AshGrpc.Test.Types.Proto.Role do
  @moduledoc false
  use Protobuf, enum: true, syntax: :proto3, full_name: "test.types.v1.Role"

  field :ROLE_UNSPECIFIED, 0
  field :ROLE_ADMIN, 1
  field :ROLE_MEMBER, 2
  field :ROLE_GUEST, 3
end

defmodule AshGrpc.Test.Types.Proto.Status do
  @moduledoc false
  use Protobuf, enum: true, syntax: :proto3, full_name: "test.types.v1.Status"

  field :STATUS_UNSPECIFIED, 0
  field :STATUS_ACTIVE, 1
  field :STATUS_ARCHIVED, 2
end

defmodule AshGrpc.Test.Types.Proto.RecordKind do
  @moduledoc false
  use Protobuf, enum: true, syntax: :proto3, full_name: "test.types.v1.RecordKind"

  field :RECORD_KIND_UNSPECIFIED, 0
  field :RECORD_KIND_SMALL, 1
  field :RECORD_KIND_LARGE, 2
end

defmodule AshGrpc.Test.Types.Proto.AddressGeo do
  @moduledoc false
  use Protobuf, syntax: :proto3, full_name: "test.types.v1.AddressGeo"

  field :lat, 1, type: :double
  field :lng, 2, type: :double
end

defmodule AshGrpc.Test.Types.Proto.Address do
  @moduledoc false
  use Protobuf, syntax: :proto3, full_name: "test.types.v1.Address"

  field :street, 1, type: :string
  field :city, 2, proto3_optional: true, type: :string
  field :zip, 3, proto3_optional: true, type: :int64
  field :tags, 4, repeated: true, type: :string
  field :geo, 5, type: AshGrpc.Test.Types.Proto.AddressGeo
end

defmodule AshGrpc.Test.Types.Proto.ContentIntsList do
  @moduledoc false
  use Protobuf, syntax: :proto3, full_name: "test.types.v1.ContentIntsList"

  field :values, 1, repeated: true, type: :int64
end

defmodule AshGrpc.Test.Types.Proto.Content do
  @moduledoc false
  use Protobuf, syntax: :proto3, full_name: "test.types.v1.Content"

  oneof(:value, 0)

  field :text, 1, type: :string, oneof: 0
  field :number, 2, type: :int64, oneof: 0
  field :day, 3, type: Google.Type.Date, oneof: 0
  field :ints, 4, type: AshGrpc.Test.Types.Proto.ContentIntsList, oneof: 0
end

defmodule AshGrpc.Test.Types.Proto.LabelsItem do
  @moduledoc false
  use Protobuf, syntax: :proto3, full_name: "test.types.v1.LabelsItem"

  field :value, 1, proto3_optional: true, type: :string
end

defmodule AshGrpc.Test.Types.Proto.MatrixList do
  @moduledoc false
  use Protobuf, syntax: :proto3, full_name: "test.types.v1.MatrixList"

  field :values, 1, repeated: true, type: :int64
end

defmodule AshGrpc.Test.Types.Proto.ScoresList do
  @moduledoc false
  use Protobuf, syntax: :proto3, full_name: "test.types.v1.ScoresList"

  field :values, 1, repeated: true, type: :int64
end

defmodule AshGrpc.Test.Types.Proto.Profile do
  @moduledoc false
  use Protobuf, syntax: :proto3, full_name: "test.types.v1.Profile"

  field :bio, 1, proto3_optional: true, type: :string
  field :role, 2, proto3_optional: true, type: AshGrpc.Test.Types.Proto.Role, enum: true
  field :birthday, 3, type: Google.Type.Date
end

defmodule AshGrpc.Test.Types.Proto.Record do
  @moduledoc false
  use Protobuf, syntax: :proto3, full_name: "test.types.v1.Record"

  field :id, 1, type: :string
  field :name, 2, proto3_optional: true, type: :string
  field :count, 3, proto3_optional: true, type: :int64
  field :ratio, 4, proto3_optional: true, type: :double
  field :price, 5, proto3_optional: true, type: :string
  field :active, 6, type: :bool
  field :born_on, 7, type: Google.Type.Date
  field :wakes_at, 8, type: Google.Type.TimeOfDay
  field :inserted_at, 9, type: Google.Protobuf.Timestamp
  field :local_at, 10, proto3_optional: true, type: :string
  field :ttl, 11, type: Google.Protobuf.Duration
  field :role, 12, proto3_optional: true, type: AshGrpc.Test.Types.Proto.Role, enum: true
  field :status, 13, proto3_optional: true, type: AshGrpc.Test.Types.Proto.Status, enum: true
  field :kind, 14, proto3_optional: true, type: AshGrpc.Test.Types.Proto.RecordKind, enum: true
  field :meta, 15, type: Google.Protobuf.Struct
  field :payload, 16, type: Google.Protobuf.Value
  field :address, 17, type: AshGrpc.Test.Types.Proto.Address
  field :content, 18, type: AshGrpc.Test.Types.Proto.Content
  field :labels, 19, repeated: true, type: AshGrpc.Test.Types.Proto.LabelsItem
  field :matrix, 20, repeated: true, type: AshGrpc.Test.Types.Proto.MatrixList
  field :scores, 21, type: AshGrpc.Test.Types.Proto.ScoresList
  field :tags, 22, repeated: true, type: :string
  field :profile, 23, type: AshGrpc.Test.Types.Proto.Profile
  field :profiles, 24, repeated: true, type: AshGrpc.Test.Types.Proto.Profile
  field :money, 25, type: Google.Type.Money
  field :slug, 26, type: Google.Protobuf.StringValue
  field :raw_id, 27, proto3_optional: true, type: :bytes
  field :exact, 28, type: Google.Type.Decimal
  field :big, 29, proto3_optional: true, type: :string
  field :small, 30, proto3_optional: true, type: :int32
  field :module, 31, proto3_optional: true, type: :string
end

defmodule AshGrpc.Test.Types.Proto.Pair do
  @moduledoc false
  use Protobuf, syntax: :proto3, full_name: "test.types.v1.Pair"

  field :a, 1, proto3_optional: true, type: :string
  field :b, 2, proto3_optional: true, type: :int64
end
