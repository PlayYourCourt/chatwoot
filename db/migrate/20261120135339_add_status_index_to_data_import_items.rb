class AddStatusIndexToDataImportItems < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!

  INDEX_NAME = 'idx_data_import_items_on_import_type_and_status'.freeze

  # salesforce:report groups an import's items by type and status; on a million items that needs an index.
  # Building it takes longer than the 14s statement timeout, and a build that was cancelled part-way leaves
  # an invalid index behind, so drop any leftover and lift the timeout for this session before building.
  def up
    remove_index :data_import_items, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
    connection.execute('SET statement_timeout = 0')
    add_index :data_import_items, [:data_import_id, :source_object_type, :status], name: INDEX_NAME, algorithm: :concurrently
  end

  def down
    remove_index :data_import_items, name: INDEX_NAME, algorithm: :concurrently, if_exists: true
  end
end
