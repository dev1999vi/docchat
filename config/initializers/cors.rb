# Allow the React frontend (Vite dev server) to call the API.
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins ENV.fetch("FRONTEND_ORIGIN", "http://localhost:5173")

    resource "*",
      headers: :any,
      methods: [ :get, :post, :delete, :options ],
      expose: [ "Content-Type" ]
  end
end
