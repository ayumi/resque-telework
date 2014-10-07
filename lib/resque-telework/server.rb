module Resque
  module Plugins
    module Telework
      module Server

        require 'erb'

        VIEW_PATH = File.join(File.dirname(__FILE__), 'server', 'views')
        PUBLIC_PATH = File.join(File.dirname(__FILE__), 'server', 'public')

        def self.registered( app )
          app.enable :sessions

          appn= 'Telework'

          # Can't set public_folder as it would overwrite the resque one
          app.get "/#{appn.downcase}/public/:file" do
            send_file(File.join(PUBLIC_PATH, params[:file]), :disposition => 'inline')
          end

          # This helpers adds stuff to the app closure
          app.helpers do
            @@myredis= TeleworkRedis.new
            def redis
              @@myredis
            end
            def my_substabs
              ["Overview", "Start", "Restore", "Stats", "Notes", "Tags", "Misc"]
            end
            def my_show(page, layout = true)
              response["Cache-Control"] = "max-age=0, private, must-revalidate"
              begin
                erb(File.read(File.join(VIEW_PATH, "#{page}.erb")), {:layout => layout}, :resque => Resque)
              rescue Errno::ECONNREFUSED
                erb :error, {:layout => false}, :error => "Can't connect to Redis! (#{Resque.redis_id})"
              end
            end
            def generic_filter(id, name, list, more= "")
              html = "<select id=\"#{id}\" name=\"#{name}\" #{more}>"
              value= list[0]
              list.each do |k|
                selected = k == value ? 'selected="selected"' : ''
                html += "<option #{selected} value=\"#{k}\">#{k}</option>"
              end
              html += "</select>"
            end
            def generic_filter_with_dis(id, name, list, more= "")
              html = "<select id=\"#{id}\" name=\"#{name}\" #{more}>"
              value= list[0][0] if list[0]
              list.each do |k,dis|
                selected = k == value ? 'selected="selected"' : ''
                html += "<option #{selected} value=\"#{k}\">#{dis}</option>"
              end
              html += "</select>"
            end
            def task_default
              { 'auto_max_waiting_job_per_worker' => 1,'auto_worker_min' => 0, 'auto_delay' => 15,
                'log_snapshot_period' => 30, 'log_snapshot_lines' => 40, 'exec' => "bundle exec rake resque:work --trace", 'env_vars' => ''
              }
            end

            def start_task(host, task_id, count, rev)
              rev_split= rev.split(',')
              task= redis.tasks_by_id(host, task_id)
              id= []
              for i in 1..count.to_i do
                w= task
                w['worker_id']= redis.unique_id.to_s
                id << w['worker_id']
                w['worker_status']= 'Starting'
                w['revision']= rev_split[0]
                w['revision_small']= rev_split[1]
                w['command']= 'start_worker'
                w['task_id']= task_id
                redis.cmds_push( host, w )
              end
              task['worker_id']= id
              task['worker_count']= count
              redis.tasks_add( host, task_id, task )
            end

            def signal_task(host, task_id, signal)
              task= redis.tasks_by_id(host, task_id)
              task['worker_id'].each do |id|
                redis.cmds_push( host, { 'command' => 'signal_worker', 'worker_id'=> id, 'action' => signal } )
              end
            end

            def save_snapshot
              redis.create_snapshot
            end
          end

          app.get "/#{appn.downcase}" do
            redirect "/resque/#{appn.downcase}/Overview"
          end

          app.get "/#{appn.downcase}/Overview" do
            @refresh= nil
            if params[:refresh]
              @refresh= params[:refresh].to_i
              @refresh= nil if @refresh==0
            end
            @status_messages= 100
            @scheduling= nil
            my_show appn.downcase
          end

          app.get "/#{appn.downcase}/Start" do
            @dont_show_refresh= true
            @status_messages= 100
            @scheduling= true
            my_show appn.downcase
          end

          app.get "/#{appn.downcase}/Restore" do
            my_show 'restore'
          end

          app.get "/#{appn.downcase}/Misc" do
            my_show 'misc'
          end

          app.get "/#{appn.downcase}/Notes" do
            my_show 'notes'
          end

          app.get "/#{appn.downcase}/Tags" do
            @tags = Resque::Plugins::Telework::QUEUE_TAGS
            @tags_to_queues = @tags.inject({}) { |hash, tag| hash[tag] = redis.queues_with_tag(tag); hash }
            my_show 'tags'
          end

          app.post "/#{appn.downcase}/Tags" do
            if params[:_method] == 'DELETE'
              redis.remove_tag_from_queue(params[:tag], params[:queue])
            elsif params[:queue].present?
              redis.add_tag_to_queue(params[:tag], params[:queue])
            end
            redirect "/resque/#{appn.downcase}/Tags"
          end

          app.get "/#{appn.downcase}/Stats" do
            my_show 'stats'
          end

          app.get "/#{appn.downcase}/revision/:revision" do
            @revision= params[:revision]
            my_show 'revision'
          end

          app.get "/#{appn.downcase}/worker/:host/:worker" do
            @worker= params[:worker]
            @host= params[:host]
            my_show 'worker'
          end

          app.get "/#{appn.downcase}/task/:host/:task_id" do
            @task_id= params[:task_id]
            @host= params[:host]
            my_show 'task'
          end

          app.get "/#{appn.downcase}/host/:host" do
            @host= params[:host]
            my_show 'host'
          end

          app.get "/#{appn.downcase}/config" do
            content_type :json
            redis.configuration
          end

          app.post "/#{appn.downcase}_stopit/:worker" do
            @worker= params[:worker]
            @host= nil
            @daemon= nil
            redis.hosts.each do |h|
              redis.workers(h).each do |id, info|
                @host= h if id==@worker # TODO: break nested loops
              end
            end
            redis.cmds_push( @host, { 'command' => 'stop_worker', 'worker_id'=> @worker } ) if @host
            my_show 'stopit'
          end

          app.post "/#{appn.downcase}_stopitd/:host" do
            # Todo - check that the host indeed exists
            @host= params[:host]
            @daemon= true
            redis.cmds_push( @host, { 'command' => 'stop_daemon' } )
            my_show 'stopit'
          end

          app.post "/#{appn.downcase}_killitd/:host" do
            # Todo - check that the host indeed exists
            @host= params[:host]
            @daemon= true
            @kill= true
            redis.cmds_push( @host, { 'command' => 'kill_daemon' } )
            my_show 'stopit'
          end

          app.post "/#{appn.downcase}_del_host/:host" do
            host= params[:host]
            redis.hosts_rem( host )
            redis.aliases_rem( host )
            redirect "/resque/#{appn.downcase}"
          end

          app.post "/#{appn.downcase}_mod_host/:host" do
            host= params[:host]
            ahost= params[:alias]
            comment= params[:comment]
            if ahost.blank? || ahost==host
              redis.aliases_rem( host )
            else
              redis.aliases_add( host, ahost )
            end
            if comment.blank?
              redis.comments_rem( host )
            else
              redis.comments_add( host, comment )
            end
            redirect "/resque/#{appn.downcase}"
          end

          app.post "/#{appn.downcase}_mod_task/:task" do
            @task_id= params[:task]
            @host= nil
            redis.hosts.each do |h|
              redis.tasks(h).each do |id, info|
                @host= h if id==@task_id # TODO: break nested loops
              end
            end
            @task= redis.tasks_by_id( @host, @task_id )
            all= ['log_snapshot_period', 'log_snapshot_lines', 'exec', 'env_vars', 'worker_count',
                  'auto_delay', 'auto_max_waiting_job_per_worker', 'auto_worker_min' ]
            all.each do |a|
              @task[a]= params[a]
            end
            redis.tasks_add( @host , @task_id, @task )
            redirect "/resque/#{appn.downcase}"
          end

          app.post "/#{appn.downcase}_killit/:worker" do
            @worker= params[:worker]
            @host= nil
            @kill= true
            redis.hosts.each do |h|
              redis.workers(h).each do |id, info|
                @host= h if id==@worker # TODO: break nested loops
              end
            end
            redis.cmds_push( @host, { 'command' => 'kill_worker', 'worker_id'=> @worker } ) if @host
            my_show 'stopit'
          end

          app.post "/#{appn.downcase}/add_note" do
            @user= params[:note_user]
            @date= Time.now
            @note= params[:note_text]
            redis.notes_push({ 'user'=> @user, 'date'=> @date, 'note' => @note })
            redirect back
          end

          app.post "/#{appn.downcase}_del_note/:note" do
            @note_id= params[:note]
            redis.notes_del(@note_id)
            redirect back
          end

          # Start a task
          app.post "/telework/start_task" do
            @host= params[:h]
            @queue= params[:q]
            @qmanual= params[:qmanual]
            @count= params[:c]
            #@rev= params[:r].split(' ')
            @envv= params[:e]
            @q= @qmanual.blank? ? @queue : @qmanual
            id= redis.unique_id.to_s
            t= task_default
            redis.tasks_add( @host , id, t.merge( { 'task_id' => id, 'worker_count' => @count,
                                                    'rails_env' => @envv, 'queue' => @q,
                                                    'worker_id' => [], 'worker_status' => 'Stopped'} ) )
            redirect "/resque/#{appn.downcase}"
          end

          # Restore tasks from worker image
          app.post "/telework/restore_tasks" do
            @host = params[:h]
            @source_host = params[:source]

            # Copy from an active host
            if redis.hosts.include?(@source_host)
              redis.tasks(@source_host).each do |(id, task_params)|
                task_params.delete("revision")
                task_params.delete("revision_small")
                task_params.delete("command")
                task_params["worker_id"] = []
                task_params["worker_status"] = ""
                task_params["worker_pid"] = []

                new_task_id = redis.unique_id.to_s
                redis.tasks_add( @host, new_task_id, task_params )
              end
            end

            # TODO: Copy from a backup host task list

            redirect "/resque/#{appn.downcase}"
          end

          # TODO: Backup worker task list

          app.post "/#{appn.downcase}/delete" do
            @task_id= params[:task]
            @host= params[:host]
            redis.tasks_rem( @host, @task_id )
            redirect "/resque/#{appn.downcase}"
          end

          # Start workers
          app.post "/#{appn.downcase}/start" do
            start_task(params[:host], params[:task], params[:count], params[:rev])
            redirect "/resque/#{appn.downcase}"
          end

          app.post "/#{appn.downcase}/start_auto" do
            @task_id= params[:task]
            @host= params[:host]
            @rev= params[:rev].split(',')
            @task= redis.tasks_by_id(@host, @task_id)
            count= params[:count]
            wid= []
            for i in 1..count.to_i do
              wid << redis.unique_id.to_s
              #redis.cmds_push( @host, w )
            end
            @task['worker_id']= wid
            @task['worker_count']= count
            @task['mode']= 'auto'
            cmd= @task
            cmd['task_id']= @task_id
            cmd['revision']= @rev[0]
            cmd['revision_small']= @rev[1]
            cmd['command']= 'start_auto'
            redis.cmds_push( @host, cmd )
            redis.tasks_add( @host, @task_id, @task )
            redirect "/resque/#{appn.downcase}"
          end

          app.post "/#{appn.downcase}/stop_auto" do
            @task_id= params[:task]
            @host= params[:host]
            @task= redis.tasks_by_id(@host, @task_id)
            cmd= @task
            cmd['command']= 'stop_auto'
            redis.cmds_push( @host, cmd )
            redirect "/resque/#{appn.downcase}"
          end


          app.post "/#{appn.downcase}/pause" do
            signal = @cont ? 'KILL' : 'QUIT'
            signal_task(params[:host], params[:task], signal)
            redirect "/resque/#{appn.downcase}"
          end

          app.post "/#{appn.downcase}/stop" do
            signal = params[:kill] == 'true' ? 'KILL' : 'QUIT'
            signal_task(params[:host], params[:task], signal)
            redirect "/resque/#{appn.downcase}"
          end

          app.post "/#{appn.downcase}/stop_all" do
            @kill= params[:mode]=="Kill"
            hl= [ params[:h] ]
            hl= redis.hosts if params[:h]=="[All hosts]"
            hl.each do |h|
              redis.workers(h).each do |id, info|
                unless info['worker_status']=='Stopped'
                  redis.cmds_push( h, { 'command' => 'signal_worker', 'worker_id'=> id, 'action' => @kill ? 'KILL' : 'QUIT' } )
                end
              end
            end
            redirect "/resque/#{appn.downcase}"
          end

          app.post "/#{appn.downcase}/batch_action" do
            hosts_to_tasks = redis.hosts.inject({}) { |hash, host| hash[host] = Hash[redis.tasks(host)]; hash }
            action = params[:action].downcase
            tasks = ActiveSupport::JSON.decode(params[:tasks])

            tasks.each do |task|
              host = task['host']
              task_id = task['task_id']
              status = hosts_to_tasks[host][task_id].try(:[], 'worker_status')
              case action
              when 'start'
                start_task(host, task_id, task['count'], task['rev']) unless %w{Running Resuming}.include?(status)
              when 'stop'
                signal_task(host, task_id, 'QUIT') if %w{Running Resuming}.include?(status)
              when 'kill'
                signal_task(host, task_id, 'KILL') if %w{Running Resuming}.include?(status)
              when 'delete'
                redis.tasks_rem(host, task_id) if ['Stopped', ''].include?(status)
              else
                raise "Invalid action: #{action}"
              end
            end
            redirect "/resque/#{appn.downcase}"
          end

          app.post "/#{appn.downcase}/snapshot" do
            action = params[:action]
            case action
            when 'snapshot'
              is_snapshot_saved = redis.set_snapshot
              unless is_snapshot_saved
                session[:notice] = 'Unable to save a snapshot, as no workers are running.'
              end
            when 'snapshot_and_stop'
              is_snapshot_saved = redis.set_snapshot
              if is_snapshot_saved
                redis.hosts.each do |host|
                  redis.tasks(host).each do |task_id, task|
                    status = task['worker_status']
                    if %w{Running Resuming}.include?(status)
                      signal_task(host, task_id, 'QUIT')
                    end
                  end
                end
                session[:notice] = 'Saving snapshot and stopping all workers...'
              else
                session[:notice] = 'Unable to save a snapshot, as no workers are running.'
              end
            when 'restore_snapshot'
              is_any_task_running = redis.hosts.any? { |host| redis.tasks(host).any? { |task_id, task| %w{Running Resuming}.include?(task['worker_status']) } }
              if is_any_task_running
                session[:notice] = 'Unable to restore the snapshot, as workers are running. Please stop all workers before restoring a snapshot.'
              else
                snapshot = redis.get_snapshot
                snapshot['hosts'].each do |host, host_snapshot|
                  host_snapshot['tasks'].each do |task_id, status|
                    if %w{Running Resuming}.include?(status)
                      task = redis.tasks_by_id(host, task_id)
                      rev = "#{task['revision']},#{task['revision_small']}"
                      start_task(host, task_id, task['worker_count'], rev)
                    end
                  end
                end
                session[:notice] = 'Restoring snapshot...'
              end
            else
              raise "Invalid action: #{action}"
            end
            redirect "/resque/#{appn.downcase}"
          end

          app.tabs << appn

        end

      end
    end
  end
end

Resque::Server.register Resque::Plugins::Telework::Server
